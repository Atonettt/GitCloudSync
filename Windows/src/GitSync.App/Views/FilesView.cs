using GitSync.App.Services;
using GitSync.Core;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;

namespace GitSync.App.Views;

/// <summary>
/// The repository folder as it is on disk: browse it like File Explorer, see which files aren't
/// synced yet or changed at the last sync, and preview or compare the selected file.
/// </summary>
public sealed class FilesView
{
    sealed record Item(string Name, string Path, bool IsDirectory, long? Size, DateTimeOffset? Modified);

    readonly AppModel model;
    readonly Guid id;
    public Grid Element { get; } = Ui.Grid("300,1,*");
    readonly ListView list = new() { SelectionMode = ListViewSelectionMode.Single };
    readonly StackPanel breadcrumb = new() { Orientation = Orientation.Horizontal, Spacing = 2 };
    readonly Button back;
    readonly ContentControl previewHost = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch };
    readonly Grid previewHeader = Ui.Grid("auto,*,auto");
    readonly TextBlock empty = Ui.Caption("");
    List<Item> items = [];
    HashSet<string> unsynced = [];
    Dictionary<string, char> recent = [];
    DateTimeOffset? recentDate;
    string folder = "";
    string? selection;
    bool comparing;
    FileSystemWatcher? watcher;
    CancellationTokenSource? previewLoad;
    bool wasSyncing;

    string Root => model.Repository(id)?.Path ?? "";

    public FilesView(AppModel model, Guid id)
    {
        this.model = model;
        this.id = id;
        back = Ui.IconButton(Glyph.Back, L.T("返回上一级", "Up one level"), () => Navigate(ParentOf(folder)), 12);

        var left = Ui.Grid(rows: "auto,auto,*");
        var top = Ui.Row(2, back, new ScrollViewer { Content = breadcrumb, HorizontalScrollBarVisibility = ScrollBarVisibility.Hidden, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled });
        top.Padding = new Thickness(8, 6, 8, 6);
        left.Children.Add(top.At(0));
        left.Children.Add(new Border { Height = 1, Background = Ui.Divider }.At(1));
        var listHost = new Grid();
        listHost.Children.Add(list);
        empty.HorizontalAlignment = HorizontalAlignment.Center;
        empty.VerticalAlignment = VerticalAlignment.Center;
        listHost.Children.Add(empty);
        left.Children.Add(listHost.At(2));

        list.SelectionChanged += (_, _) =>
        {
            if (list.SelectedItem is not ListViewItem { Tag: Item item }) return;
            if (item.IsDirectory) { Navigate(item.Path); return; }
            selection = item.Path;
            _ = ShowPreview(item);
        };
        list.DoubleTapped += (_, _) => { if (list.SelectedItem is ListViewItem { Tag: Item item }) Shell.Open(Full(item.Path)); };

        var right = Ui.Grid(rows: "auto,auto,*");
        previewHeader.Padding = new Thickness(16, 10, 16, 10);
        previewHeader.ColumnSpacing = 12;
        right.Children.Add(previewHeader.At(0));
        right.Children.Add(new Border { Height = 1, Background = Ui.Divider }.At(1));
        right.Children.Add(previewHost.At(2));

        Element.Children.Add(left.At(0, 0));
        Element.Children.Add(new Border { Width = 1, Background = Ui.Divider }.At(0, 1));
        Element.Children.Add(right.At(0, 2));

        model.Changed += OnModelChanged;
        Element.Unloaded += (_, _) => { model.Changed -= OnModelChanged; watcher?.Dispose(); };
        Navigate("");
    }

    void OnModelChanged(Guid? changed)
    {
        if (changed != null && changed != id) return;
        var syncing = model.State(id).IsSyncing;
        if (wasSyncing && !syncing) _ = Reload();   // a sync finished: files may have changed
        wasSyncing = syncing;
    }

    string Full(string relative) => Path.Combine(Root, relative.Replace('/', '\\'));
    static string ParentOf(string path) => path.Contains('/') ? path[..path.LastIndexOf('/')] : "";

    void Navigate(string path)
    {
        folder = path;
        Watch();
        _ = Reload();
    }

    /// <summary>The list follows the folder by itself: files added, removed or renamed (in Explorer or another app).</summary>
    void Watch()
    {
        watcher?.Dispose();
        watcher = null;
        var directory = folder.Length == 0 ? Root : Full(folder);
        if (!Directory.Exists(directory)) return;
        try
        {
            watcher = new FileSystemWatcher(directory) { IncludeSubdirectories = false, NotifyFilter = NotifyFilters.FileName | NotifyFilters.DirectoryName | NotifyFilters.LastWrite | NotifyFilters.Size };
            var pending = 0;
            void Changed(object? _, FileSystemEventArgs __)
            {
                // Coalesce bursts (a save writes several times) into one reload.
                if (Interlocked.Exchange(ref pending, 1) == 1) return;
                DispatcherQueueExtensions.RunOnUi(async () =>
                {
                    await Task.Delay(400);
                    Interlocked.Exchange(ref pending, 0);
                    await Reload();
                });
            }
            watcher.Created += Changed;
            watcher.Deleted += Changed;
            watcher.Changed += Changed;
            watcher.Renamed += (s, e) => Changed(s, e);
            watcher.EnableRaisingEvents = true;
        }
        catch { /* not watchable (network drive): reloads after syncs only */ }
    }

    async Task Reload()
    {
        var directory = folder.Length == 0 ? Root : Full(folder);
        if (!Directory.Exists(directory))
        {
            if (folder.Length > 0) { Navigate(""); return; }
            items = [];
        }
        else
        {
            var prefix = folder.Length == 0 ? "" : folder + "/";
            items = await Task.Run(() =>
            {
                var info = new DirectoryInfo(directory);
                return info.EnumerateFileSystemInfos()
                    .Where(e => !e.Name.StartsWith('.') && !e.Attributes.HasFlag(FileAttributes.Hidden))
                    .Select(e => new Item(e.Name, prefix + e.Name, e is DirectoryInfo, e is FileInfo f ? f.Length : null, e.LastWriteTime))
                    .OrderByDescending(i => i.IsDirectory).ThenBy(i => i.Name, StringComparer.CurrentCultureIgnoreCase).ToList();
            });
        }
        unsynced = await model.UnsyncedPathsAsync(id);
        if (model.HistoryBrowser(id) is { } browser)
        {
            var last = await browser.LastSyncChangesAsync();
            recent = last.Changes;
            recentDate = last.Date;
        }
        Render();
    }

    void Render()
    {
        UpdateBreadcrumb();
        back.Visibility = folder.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        list.Items.Clear();
        foreach (var item in items) list.Items.Add(new ListViewItem { Content = Row(item), Tag = item, ContextFlyout = ContextMenu(item), Padding = new Thickness(10, 4, 10, 4) });
        empty.Text = items.Count == 0 ? L.T("这个文件夹是空的", "This folder is empty") : "";
        // Keep the selection; otherwise preview the first file right away.
        var target = items.FirstOrDefault(i => i.Path == selection && !i.IsDirectory) ?? items.FirstOrDefault(i => !i.IsDirectory);
        if (target != null)
        {
            list.SelectedItem = list.Items.OfType<ListViewItem>().FirstOrDefault(r => r.Tag == target);
            if (target.Path != selection || previewHost.Content == null) { selection = target.Path; _ = ShowPreview(target); }
            else UpdatePreviewHeader(target);
        }
        else
        {
            selection = null;
            ShowFolderSummary();
        }
    }

    void UpdateBreadcrumb()
    {
        breadcrumb.Children.Clear();
        var name = model.Repository(id)?.DisplayName ?? "";
        breadcrumb.Children.Add(Crumb(name, "", folder.Length == 0));
        var path = "";
        foreach (var part in folder.Split('/', StringSplitOptions.RemoveEmptyEntries))
        {
            path = path.Length == 0 ? part : path + "/" + part;
            breadcrumb.Children.Add(Ui.Icon("", 10, Ui.Tertiary));
            breadcrumb.Children.Add(Crumb(part, path, path == folder));
        }
    }

    UIElement Crumb(string text, string target, bool current)
    {
        var button = new HyperlinkButton { Content = new TextBlock { Text = text, FontWeight = current ? FontWeights.SemiBold : FontWeights.Normal }, Padding = new Thickness(4, 2, 4, 2) };
        button.Click += (_, _) => Navigate(target);
        return button;
    }

    UIElement Row(Item item)
    {
        var grid = Ui.Grid("24,*,auto,auto");
        grid.ColumnSpacing = 6;
        grid.Children.Add(Ui.Icon(FileGlyph(item), 16, item.IsDirectory ? Ui.Accent : Ui.Secondary).At(0, 0));
        grid.Children.Add(Ui.Text(item.Name, 13).Tooltip(item.Name).At(0, 1));
        if (Badge(item) is { } badge) grid.Children.Add(Ui.Badge(badge.Text, badge.Color).Tooltip(badge.Help).At(0, 2));
        else if (item.IsDirectory && recent.Keys.Any(k => k.StartsWith(item.Path + "/")))
            grid.Children.Add(new Microsoft.UI.Xaml.Shapes.Ellipse { Width = 7, Height = 7, Fill = Ui.Blue }.Tooltip(L.T("里面有文件在上一次同步时改动过", "Some files inside changed at the last sync")).At(0, 2));
        if (!item.IsDirectory && item.Size is { } size) grid.Children.Add(Ui.Caption(Ui.Bytes(size)).At(0, 3));
        return grid;
    }

    static string FileGlyph(Item item)
    {
        if (item.IsDirectory) return Glyph.Folder;
        var ext = Path.GetExtension(item.Name).ToLowerInvariant();
        return ext switch
        {
            _ when ContentExtractor.ImageTypes.Contains(ext) => "",
            ".pdf" => "",
            ".mp4" or ".mov" or ".mkv" or ".avi" => "",
            ".mp3" or ".wav" or ".m4a" or ".flac" => "",
            ".zip" or ".rar" or ".7z" => "",
            _ => Glyph.Document,
        };
    }

    (string Text, SolidColorBrush Color, string Help)? Badge(Item item)
    {
        if (IgnoreRules.IsIgnored(item.Name, model.Settings.IgnorePatterns))
            return (L.T("不同步", "Not synced"), Ui.Gray, L.T("符合忽略规则，不会上传", "Matches the ignore rules and isn't uploaded"));
        if (!item.IsDirectory && item.Size is { } size && size > (long)Math.Max(1, model.Settings.LargeFileLimitMB) * 1024 * 1024)
            return (L.T("超过上限", "Too large"), Ui.Orange, L.T("超过上传上限，只保留在本机", "Over the upload limit; kept on this computer only"));
        if (IsPending(item)) return (L.T("未同步", "Unsynced"), Ui.Orange, L.T("还没有上传到 GitHub", "Not uploaded to GitHub yet"));
        if (item.IsDirectory) return null;
        var when = recentDate is { } d ? Ui.Date(d) : "";
        return recent.GetValueOrDefault(item.Path) switch
        {
            'A' => (L.T("新增", "New"), Ui.Green, L.T($"上一次同步（{when}）时新增，切到「对比改动」可以看具体内容", $"Added at the last sync ({when})")),
            'M' => (L.T("已修改", "Modified"), Ui.Blue, L.T($"上一次同步（{when}）时改动，切到「对比改动」可以看具体改了什么", $"Changed at the last sync ({when}); switch to Compare Changes to see what changed")),
            _ => null,
        };
    }

    bool IsPending(Item item) => item.IsDirectory ? unsynced.Any(p => p.StartsWith(item.Path + "/")) : unsynced.Contains(item.Path);

    MenuFlyout ContextMenu(Item item)
    {
        var menu = new MenuFlyout();
        menu.Items.Add(Ui.MenuItem(item.IsDirectory ? L.T("打开文件夹", "Open Folder") : L.T("打开", "Open"),
                                   () => { if (item.IsDirectory) Navigate(item.Path); else Shell.Open(Full(item.Path)); }, Glyph.Open));
        menu.Items.Add(Ui.MenuItem(L.T("在资源管理器中显示", "Show in Explorer"), () => Shell.Reveal(Full(item.Path)), Glyph.FolderOpen));
        if (!item.IsDirectory) menu.Items.Add(Ui.MenuItem(L.T("历史版本", "History"), () => HistoryWindow.Show(model, id, item.Path), Glyph.History));
        if (IsPending(item))
        {
            menu.Items.Add(new MenuFlyoutSeparator());
            menu.Items.Add(Ui.MenuItem(L.T("还原为云端版本…", "Revert to GitHub Version…"), () => _ = ConfirmRevert(item), Glyph.Undo));
        }
        return menu;
    }

    async Task ConfirmRevert(Item item)
    {
        var message = item.IsDirectory
            ? L.T("这个文件夹里还没同步的修改会被丢弃，换回 GitHub 上现在的内容。只在本机的新文件不受影响；丢弃的内容会在本机保留一份备份。",
                  "Unsynced changes in this folder are discarded and replaced with what's on GitHub now. New files only on this computer are kept; a backup is kept.")
            : L.T("这个文件还没同步的修改会被丢弃，换回 GitHub 上现在的内容。丢弃的内容会在本机保留一份备份。",
                  "Unsynced changes to this file are discarded and replaced with what's on GitHub now. A backup is kept on this computer.");
        if (await Ui.Ask(Element.XamlRoot, L.T($"将「{item.Name}」还原为 GitHub 上的版本？", $"Revert “{item.Name}” to its GitHub version?"), message,
                         L.T("还原", "Revert"), destructive: true) == ContentDialogResult.Primary)
            await model.RevertToCloudAsync(id, [item.Path]);
    }

    // MARK: Preview

    void UpdatePreviewHeader(Item item)
    {
        previewHeader.Children.Clear();
        previewHeader.Children.Add(Ui.Icon(FileGlyph(item), 28, Ui.Secondary).At(0, 0));
        var details = new List<string>();
        if (item.Size is { } size) details.Add(Ui.Bytes(size));
        if (item.Modified is { } modified) details.Add(L.T($"修改于 {Ui.Date(modified)}", $"Modified {Ui.Date(modified)}"));
        details.Add(Badge(item)?.Text ?? L.T("已同步", "Synced"));
        previewHeader.Children.Add(Ui.Column(2, Ui.Text(item.Name, 14, FontWeights.SemiBold), Ui.Caption(string.Join(" · ", details))).At(0, 1));
        var segmented = new SelectorBar();
        var preview = new SelectorBarItem { Text = L.T("预览", "Preview"), IsSelected = !comparing };
        var compare = new SelectorBarItem { Text = L.T("对比改动", "Compare Changes"), IsSelected = comparing };
        segmented.Items.Add(preview);
        segmented.Items.Add(compare);
        segmented.SelectionChanged += (_, _) =>
        {
            var wantCompare = segmented.SelectedItem == compare;
            if (wantCompare == comparing) return;
            comparing = wantCompare;
            _ = ShowPreview(item);
        };
        ToolTipService.SetToolTip(segmented, IsPending(item) ? L.T("对比改动：标出你还没同步的修改", "Compare Changes: mark the edits not synced yet")
                                                              : L.T("对比改动：标出这个文件和上一个时间节点相比改了哪些地方", "Compare Changes: what changed since the previous sync point"));
        previewHeader.Children.Add(segmented.At(0, 2));
    }

    async Task ShowPreview(Item item)
    {
        previewLoad?.Cancel();
        var load = previewLoad = new CancellationTokenSource();
        UpdatePreviewHeader(item);
        previewHost.Content = new ProgressRing { IsActive = true, Width = 28, Height = 28 };
        UIElement content;
        try
        {
            content = comparing ? await Comparison(item) : await PreviewView.CreateAsync(Full(item.Path), Path.GetExtension(item.Name));
        }
        catch (Exception error)
        {
            content = PreviewView.Centered(Ui.Column(8, Ui.Icon(Glyph.Warning, 32, Ui.Tertiary), Ui.Caption(error.Message, wrap: true)));
        }
        if (!load.IsCancellationRequested) previewHost.Content = content;
    }

    /// <summary>Unsynced: against the last synced version (GitHub's). Synced: against the sync point before the last one.</summary>
    async Task<UIElement> Comparison(Item item)
    {
        var browser = model.HistoryBrowser(id);
        var ext = Path.GetExtension(item.Name);
        if (browser == null) return await CompareView.CreateAsync(null, Full(item.Path), ext, "");
        if (IsPending(item))
        {
            string? synced = null;
            try { synced = await browser.ExportForPreviewAsync(item.Path, "HEAD", DateTimeOffset.Now); } catch { }
            return await CompareView.CreateAsync(synced, Full(item.Path), ext,
                synced == null ? L.T("新文件，还没有同步过", "New file, not synced yet")
                               : L.T("你还没同步的修改，与上次同步的版本（GitHub 上的版本）相比", "Your unsynced edits, compared with the last synced version (GitHub's)"));
        }
        var point = await browser.PreviousSyncPointAsync("HEAD", item.Path);
        if (point is not { } previous) return await CompareView.CreateAsync(null, Full(item.Path), ext, L.T("这是最早的时间节点，之前没有版本", "This is the earliest sync point"));
        var old = previous.HasFile ? await browser.ExportForPreviewAsync(item.Path, previous.Commit, previous.Date) : null;
        return await CompareView.CreateAsync(old, Full(item.Path), ext, L.T($"与上一个时间节点（{Ui.Date(previous.Date)}）相比", $"Compared with the previous sync point ({Ui.Date(previous.Date)})"));
    }

    void ShowFolderSummary()
    {
        previewHeader.Children.Clear();
        var name = folder.Length == 0 ? model.Repository(id)?.DisplayName ?? "" : folder[(folder.LastIndexOf('/') + 1)..];
        previewHost.Content = PreviewView.Centered(Ui.Column(8, Ui.Icon(Glyph.Folder, 48, Ui.Tertiary), Ui.Title(name, 16),
            Ui.Caption(items.Count == 0 ? L.T("这个文件夹是空的", "This folder is empty") : L.T($"里面有 {items.Count} 项，点左边的文件即可预览。", $"{items.Count} items. Click a file to preview it."))));
    }
}
