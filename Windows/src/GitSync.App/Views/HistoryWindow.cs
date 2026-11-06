using GitSync.App.Services;
using GitSync.Core;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Graphics;

namespace GitSync.App.Views;

/// <summary>
/// Version history: by time, by file, or recently deleted. Three columns — the list, the files of a
/// version (or the versions of a file), and a preview or comparison with save-copy and restore.
/// </summary>
public sealed class HistoryWindow : Window
{
    static readonly Dictionary<Guid, HistoryWindow> Open = [];

    public static void Show(AppModel model, Guid id, string? path = null)
    {
        if (!Open.TryGetValue(id, out var window))
        {
            window = new HistoryWindow(model, id);
            Open[id] = window;
            window.Closed += (_, _) => Open.Remove(id);
        }
        window.Activate();
        if (path != null) window.SelectFile(path);
    }

    sealed record Target(string Path, string Commit, DateTimeOffset Date, string Subtitle, string RestorePath, bool CanRestore, string? Reason = null);

    readonly AppModel model;
    readonly Guid id;
    readonly HistoryBrowser? browser;
    readonly ListView left = new() { SelectionMode = ListViewSelectionMode.Single };
    readonly ListView middle = new() { SelectionMode = ListViewSelectionMode.Single };
    readonly TextBox filter = new() { PlaceholderText = L.T("搜索", "Search"), Margin = new Thickness(8, 6, 8, 6) };
    readonly ContentControl middleHeader = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch };
    readonly ContentControl preview = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch };
    readonly Grid previewHeader = Ui.Grid("*,auto");
    readonly Grid root = Ui.Grid("300,1,320,1,*", "auto,auto,*");
    string mode = "timeline";
    bool allFiles;
    bool comparing;
    List<HistoryCommit> timeline = [];
    List<string> tracked = [];
    List<DeletedFile> deleted = [];
    Target? target;
    string? pendingFile;

    HistoryWindow(AppModel model, Guid id)
    {
        this.model = model;
        this.id = id;
        browser = model.HistoryBrowser(id);
        var name = model.Repository(id)?.DisplayName ?? "";
        Title = L.T($"版本历史 · {name}", $"History · {name}");
        SystemBackdrop = new Microsoft.UI.Xaml.Media.MicaBackdrop();
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "GitSync.ico"));
        AppWindow.Resize(new SizeInt32(1320, 820));

        var modes = new SelectorBar { Margin = new Thickness(12, 6, 12, 0) };
        foreach (var (key, text) in new[] { ("timeline", L.T("按时间", "By Time")), ("files", L.T("按文件", "By File")), ("deleted", L.T("最近删除", "Recently Deleted")) })
            modes.Items.Add(new SelectorBarItem { Text = text, Tag = key, IsSelected = key == mode });
        modes.SelectionChanged += (_, _) => { mode = (string)modes.SelectedItem.Tag; _ = LoadLeft(); };
        root.Children.Add(modes.At(0, 0, columnSpan: 5));
        root.Children.Add(new Border { Height = 1, Background = Ui.Divider }.At(1, 0, columnSpan: 5));

        var leftGrid = Ui.Grid(rows: "auto,*");
        leftGrid.Children.Add(filter.At(0));
        leftGrid.Children.Add(left.At(1));
        filter.TextChanged += (_, _) => RenderLeft();
        root.Children.Add(leftGrid.At(2, 0));
        root.Children.Add(new Border { Width = 1, Background = Ui.Divider }.At(2, 1));

        var middleGrid = Ui.Grid(rows: "auto,*");
        middleGrid.Children.Add(middleHeader.At(0));
        middleGrid.Children.Add(middle.At(1));
        root.Children.Add(middleGrid.At(2, 2));
        root.Children.Add(new Border { Width = 1, Background = Ui.Divider }.At(2, 3));

        var right = Ui.Grid(rows: "auto,auto,*");
        previewHeader.Padding = new Thickness(16, 10, 16, 10);
        right.Children.Add(previewHeader.At(0));
        right.Children.Add(new Border { Height = 1, Background = Ui.Divider }.At(1));
        right.Children.Add(preview.At(2));
        root.Children.Add(right.At(2, 4));
        Content = root;

        left.SelectionChanged += (_, _) => _ = LeftSelected();
        middle.SelectionChanged += (_, _) => _ = MiddleSelected();
        ShowEmptyPreview();
        _ = LoadLeft();
    }

    void SelectFile(string path)
    {
        pendingFile = path;
        mode = "files";
        if (root.Children[0] is SelectorBar bar) bar.SelectedItem = bar.Items.First(i => (string)i.Tag == "files");
        _ = LoadLeft();
    }

    async Task LoadLeft()
    {
        left.Items.Clear();
        middle.Items.Clear();
        middleHeader.Content = null;
        target = null;
        ShowEmptyPreview();
        if (browser == null) return;
        try
        {
            switch (mode)
            {
                case "timeline": timeline = await browser.TimelineAsync(); break;
                case "files": tracked = await browser.TrackedFilesAsync(); break;
                default: deleted = await browser.DeletedFilesAsync(); break;
            }
        }
        catch (SyncFailure failure)
        {
            left.Items.Add(new ListViewItem { Content = Ui.Caption(failure.Explanation, wrap: true), IsEnabled = false });
            return;
        }
        RenderLeft();
        if (pendingFile != null && mode == "files")
        {
            left.SelectedItem = left.Items.OfType<ListViewItem>().FirstOrDefault(i => i.Tag as string == pendingFile);
            pendingFile = null;
        }
    }

    void RenderLeft()
    {
        var query = filter.Text.Trim();
        bool Match(string text) => query.Length == 0 || text.Contains(query, StringComparison.CurrentCultureIgnoreCase);
        left.Items.Clear();
        switch (mode)
        {
            case "timeline":
                foreach (var commit in timeline.Where(c => Match(c.Title) || Match(c.Source) || c.Changes.Any(ch => Match(ch.Path))))
                {
                    var icon = commit.Kind switch { CommitKind.Merge => Glyph.Download, CommitKind.Restore => Glyph.Restore, CommitKind.AutoSync => Glyph.Sync, _ => Glyph.Document };
                    var row = Ui.Grid("24,*");
                    row.Children.Add(Ui.Icon(icon, 14, Ui.Secondary).At(0, 0));
                    row.Children.Add(Ui.Column(0, Ui.Text(Ui.Date(commit.Date), 13, FontWeights.SemiBold),
                                                  Ui.Caption($"{commit.Title} · {commit.Source}"),
                                                  Ui.Caption(L.T($"{commit.Changes.Count} 个文件", $"{commit.Changes.Count} files"))).At(0, 1));
                    left.Items.Add(new ListViewItem { Content = row, Tag = commit, Padding = new Thickness(10, 6, 10, 6) });
                }
                break;
            case "files":
                foreach (var path in tracked.Where(Match))
                    left.Items.Add(new ListViewItem { Content = Ui.Column(0, Ui.Text(Path.GetFileName(path), 13), Ui.Caption(path)), Tag = path });
                break;
            default:
                foreach (var file in deleted.Where(d => Match(d.Path)))
                    left.Items.Add(new ListViewItem
                    {
                        Content = Ui.Column(0, Ui.Text(Path.GetFileName(file.Path), 13),
                                            Ui.Caption(L.T($"{file.Path} · {Ui.Date(file.DeletedIn.Date)} 删除", $"{file.Path} · deleted {Ui.Date(file.DeletedIn.Date)}"))),
                        Tag = file,
                    });
                if (deleted.Count == 0) left.Items.Add(new ListViewItem { Content = Ui.Caption(L.T("没有删除过的文件", "No deleted files")), IsEnabled = false });
                break;
        }
    }

    async Task LeftSelected()
    {
        middle.Items.Clear();
        if (browser == null || left.SelectedItem is not ListViewItem { Tag: { } tag }) return;
        switch (tag)
        {
            case HistoryCommit commit:
                await ShowCommitFiles(commit);
                break;
            case string path:
                middleHeader.Content = Header(L.T("这个文件的所有版本", "Every version of this file"));
                foreach (var version in await browser.VersionsAsync(path))
                {
                    var subtitle = version.IsDeletion ? L.T("这个版本中被删除", "Deleted in this version")
                        : (version.Size is { } size ? Ui.Bytes(size) : "") + (version.Path != path ? L.T($" · 当时名为 {version.Path}", $" · then named {version.Path}") : "");
                    middle.Items.Add(new ListViewItem
                    {
                        Content = Ui.Column(0, Ui.Text(Ui.Date(version.Commit.Date), 13, FontWeights.SemiBold), Ui.Caption($"{version.Commit.Title} · {version.Commit.Source}"), Ui.Caption(subtitle)),
                        Tag = version.IsDeletion ? null : new Target(version.Path, version.Commit.Id, version.Commit.Date, Ui.Date(version.Commit.Date), path, true),
                        IsEnabled = !version.IsDeletion,
                    });
                }
                break;
            case DeletedFile file:
                middleHeader.Content = Header(L.T("删除前的最后一个版本", "The last version before it was deleted"));
                middle.Items.Add(new ListViewItem
                {
                    Content = Ui.Column(0, Ui.Text(Path.GetFileName(file.Path), 13), Ui.Caption(file.Size is { } s ? Ui.Bytes(s) : "")),
                    Tag = new Target(file.Path, file.LastVersionCommit, file.DeletedIn.Date,
                                     L.T($"{Ui.Date(file.DeletedIn.Date)} 删除前的版本", $"Before it was deleted on {Ui.Date(file.DeletedIn.Date)}"), file.Path, true),
                });
                middle.SelectedIndex = 0;
                break;
        }
    }

    async Task ShowCommitFiles(HistoryCommit commit)
    {
        var scope = new ToggleSwitch { OnContent = L.T("全部文件", "All files"), OffContent = L.T("改动的文件", "Changed files"), IsOn = allFiles };
        scope.Toggled += (_, _) => { allFiles = scope.IsOn; _ = ShowCommitFiles(commit); };
        var restoreAll = Ui.Button(L.T("恢复整个仓库到此版本…", "Restore Everything to This Version…"), () => _ = RestoreRepository(commit), Glyph.Restore);
        middleHeader.Content = Ui.Column(4, scope, restoreAll).Also(p => p.Padding = new Thickness(10, 8, 10, 8));
        middle.Items.Clear();
        var current = (await browser!.TrackedFilesAsync()).ToHashSet();
        IEnumerable<(string Path, string Status)> entries = allFiles
            ? (await browser.TrackedFilesAsync(commit.Id)).Select(p => (p, ""))
            : commit.Changes.Select(c => (c.Path, c.DisplayStatus));
        foreach (var (path, status) in entries)
        {
            var isDeletion = !allFiles && commit.Changes.FirstOrDefault(c => c.Path == path)?.Status == "D";
            var row = Ui.Grid("*,auto");
            row.Children.Add(Ui.Column(0, Ui.Text(Path.GetFileName(path), 13), Ui.Caption(path)).At(0, 0));
            if (status.Length > 0) row.Children.Add(Ui.Caption(status).At(0, 1));
            var commitForContent = isDeletion ? commit.Parents.FirstOrDefault() ?? commit.Id : commit.Id;
            middle.Items.Add(new ListViewItem
            {
                Content = row,
                Tag = new Target(path, commitForContent, commit.Date, Ui.Date(commit.Date), path, true),
            });
        }
    }

    UIElement Header(string text) => Ui.Caption(text).Also(t => t.Margin = new Thickness(12, 8, 12, 8));

    async Task MiddleSelected()
    {
        if (middle.SelectedItem is not ListViewItem { Tag: Target selected }) return;
        target = selected;
        await ShowTarget();
    }

    void ShowEmptyPreview()
    {
        previewHeader.Children.Clear();
        preview.Content = PreviewView.Centered(Ui.Column(8, Ui.Icon(Glyph.History, 40, Ui.Tertiary), Ui.Caption(L.T("选择一个文件查看它在那个版本的样子。", "Choose a file to see it as it was."))));
    }

    async Task ShowTarget()
    {
        if (target is not { } current || browser == null) return;
        previewHeader.Children.Clear();
        previewHeader.Children.Add(Ui.Column(2, Ui.Text(Path.GetFileName(current.Path), 14, FontWeights.SemiBold), Ui.Caption(current.Subtitle)).At(0, 0));
        var bar = new SelectorBar();
        var previewItem = new SelectorBarItem { Text = L.T("预览", "Preview"), IsSelected = !comparing };
        var compareItem = new SelectorBarItem { Text = L.T("对比上一版本", "Compare with Previous"), IsSelected = comparing };
        bar.Items.Add(previewItem);
        bar.Items.Add(compareItem);
        bar.SelectionChanged += (_, _) => { if ((bar.SelectedItem == compareItem) != comparing) { comparing = !comparing; _ = ShowTarget(); } };
        var actions = Ui.Row(6, bar,
            Ui.IconButton(Glyph.Save, L.T("另存为「文件名 (日期 版本)」，当前文件不变", "Save as “name (date version)”; the current file stays"), () => _ = SaveCopy(current)),
            Ui.Button(L.T("恢复", "Restore"), () => _ = RestoreFile(current), Glyph.Restore, accent: true));
        previewHeader.Children.Add(actions.At(0, 1));
        preview.Content = new ProgressRing { IsActive = true, Width = 28, Height = 28 };

        try
        {
            var file = await browser.ExportForPreviewAsync(current.Path, current.Commit, current.Date);
            var ext = Path.GetExtension(current.Path);
            if (!comparing)
            {
                preview.Content = await PreviewView.CreateAsync(file, ext);
                return;
            }
            var point = await browser.PreviousSyncPointAsync(current.Commit, current.Path);
            if (point is not { } previous)
            {
                preview.Content = await CompareView.CreateAsync(null, file, ext, L.T("这是最早的时间节点，之前没有版本", "This is the earliest sync point"));
                return;
            }
            var old = previous.HasFile ? await browser.ExportForPreviewAsync(current.Path, previous.Commit, previous.Date) : null;
            preview.Content = await CompareView.CreateAsync(old, file, ext, L.T($"与上一个时间节点（{Ui.Date(previous.Date)}）相比", $"Compared with the previous sync point ({Ui.Date(previous.Date)})"));
        }
        catch (Exception error)
        {
            preview.Content = PreviewView.Centered(Ui.Column(8, Ui.Icon(Glyph.Warning, 32, Ui.Tertiary), Ui.Caption((error as SyncFailure)?.Explanation ?? error.Message, wrap: true)));
        }
    }

    async Task SaveCopy(Target current)
    {
        if (browser == null) return;
        try
        {
            var copy = await browser.SaveCopyAsync(current.Path, current.Commit, current.Date, current.RestorePath);
            model.Log(id, L.T("历史版本", "History"), LogLevel.Success, L.T($"已将「{current.Path}」的历史版本另存为「{copy}」，下次同步时上传", $"Saved an old version of “{current.Path}” as “{copy}”; it uploads at the next sync"));
            if (model.Repository(id) is { } repo) Shell.Reveal(Path.Combine(repo.Path, copy.Replace('/', '\\')));
        }
        catch (Exception error)
        {
            await Ui.Inform(root.XamlRoot, L.T("无法另存副本", "Couldn't Save a Copy"), (error as SyncFailure)?.FullReport ?? error.Message);
        }
    }

    async Task RestoreFile(Target current)
    {
        var message = L.T($"「{current.RestorePath}」会变成 {current.Subtitle} 的样子。现在的内容会先保存到历史里，之后还能找回。恢复后会自动同步到 GitHub。",
                          $"“{current.RestorePath}” becomes the version from {current.Subtitle}. The current content is saved to history first and can be brought back. The restore syncs to GitHub.");
        if (await Ui.Ask(root.XamlRoot, L.T("恢复这个文件？", "Restore this file?"), message, L.T("恢复", "Restore")) != ContentDialogResult.Primary) return;
        await model.RestoreAsync(id, new RestoreTarget.File(current.RestorePath, current.Path, current.Commit),
                                 L.T($"「{current.RestorePath}」到 {current.Subtitle}", $"“{current.RestorePath}” to {current.Subtitle}"));
        await LoadLeft();
    }

    async Task RestoreRepository(HistoryCommit commit)
    {
        if (browser == null) return;
        var plan = await browser.PreviewRestoreAsync(commit.Id);
        if (plan.Total == 0)
        {
            await Ui.Inform(root.XamlRoot, L.T("无需恢复", "Nothing to Restore"), L.T("现在的内容和那个版本完全一样。", "The content already matches that version."));
            return;
        }
        string List(List<string> items) => string.Join("\n", items.Take(8).Select(i => "  " + i)) + (items.Count > 8 ? L.T($"\n  …等 {items.Count} 个", $"\n  …{items.Count} in all") : "");
        var text = L.T($"整个文件夹会回到 {Ui.Date(commit.Date)} 的样子。现在的内容会先保存到历史里。\n", $"The whole folder goes back to {Ui.Date(commit.Date)}. The current content is saved to history first.\n");
        if (plan.Modified.Count > 0) text += L.T($"\n改回旧内容（{plan.Modified.Count}）：\n", $"\nChanged back ({plan.Modified.Count}):\n") + List(plan.Modified);
        if (plan.Restored.Count > 0) text += L.T($"\n找回（{plan.Restored.Count}）：\n", $"\nBrought back ({plan.Restored.Count}):\n") + List(plan.Restored);
        if (plan.Removed.Count > 0) text += L.T($"\n移除之后新建的（{plan.Removed.Count}，历史中仍可找回）：\n", $"\nRemoved, created later ({plan.Removed.Count}; still in history):\n") + List(plan.Removed);
        if (await Ui.Ask(root.XamlRoot, L.T("恢复整个仓库？", "Restore everything?"), text, L.T("恢复", "Restore"), destructive: true) != ContentDialogResult.Primary) return;
        await model.RestoreAsync(id, new RestoreTarget.Repository(commit.Id), L.T($"整个文件夹到 {Ui.Date(commit.Date)}", $"the whole folder to {Ui.Date(commit.Date)}"));
        await LoadLeft();
    }
}
