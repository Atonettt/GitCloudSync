using GitSync.App.Services;
using GitSync.Core;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;

namespace GitSync.App.Views;

/// <summary>
/// One repository's page: name and sync controls on one line, problems, three small cards, the
/// actions, and the folder itself (files with preview and comparison) filling the rest.
/// </summary>
public sealed class RepoDetailView
{
    readonly AppModel model;
    public Guid RepoId { get; }
    public Grid Element { get; } = Ui.Grid(rows: "auto,auto,auto,auto,*");
    readonly StackPanel header = new() { Orientation = Orientation.Horizontal, Spacing = 8 };
    readonly StackPanel banners = new() { Spacing = 6 };
    readonly Grid cards = Ui.Grid("*,*,*");
    readonly Grid actions = Ui.Grid("auto,*,auto");
    readonly Grid headerGrid = Ui.Grid("*,auto");
    readonly FilesView files;
    readonly ToggleSwitch autoSync = new() { OnContent = "", OffContent = "", MinWidth = 0 };
    readonly Button syncNow = new();
    bool updating;

    public RepoDetailView(AppModel model, Guid id)
    {
        this.model = model;
        RepoId = id;
        Element.Padding = new Thickness(20, 4, 20, 16);
        Element.RowSpacing = 8;

        headerGrid.Children.Add(header.At(0, 0));
        var controls = Ui.Row(10, Ui.Text(L.T("自动同步", "Auto Sync")), autoSync, new Border { Width = 1, Height = 20, Background = Ui.Divider }, syncNow);
        headerGrid.Children.Add(controls.At(0, 1));
        autoSync.Toggled += (_, _) => { if (!updating) model.SetAutoSync(id, autoSync.IsOn); };
        ToolTipService.SetToolTip(autoSync, L.T("打开后立即同步一次，之后按间隔自动同步", "Syncs now, then at the interval"));
        syncNow.Click += (_, _) => model.Sync(id, SyncTrigger.ManualSingle);
        ToolTipService.SetToolTip(syncNow, L.T("马上同步这个仓库", "Sync this repository now"));

        cards.ColumnSpacing = 10;
        Element.Children.Add(headerGrid.At(0));
        Element.Children.Add(banners.At(1));
        Element.Children.Add(cards.At(2));
        Element.Children.Add(actions.At(3));
        files = new FilesView(model, id);
        var filesBorder = new Border
        {
            Child = files.Element,
            CornerRadius = new CornerRadius(8),
            BorderBrush = Ui.CardStroke,
            BorderThickness = new Thickness(1),
            Background = Ui.CardBackground,
        };
        Element.Children.Add(filesBorder.At(4));
        BuildActions();
        Update();
    }

    public void Update()
    {
        if (model.Repository(RepoId) is not { } repo) return;
        updating = true;
        var state = model.State(RepoId);
        var status = model.DisplayStatus(repo);

        header.Children.Clear();
        header.Children.Add(Ui.Icon(Glyph.FolderOpen, 18, Ui.Accent));
        header.Children.Add(Ui.Title(repo.DisplayName, 18));
        var info = Ui.IconButton(Glyph.Info, L.T("详细信息：路径、远程地址、分支", "Details: path, remote, branch"), () => { }, 13);
        info.Flyout = new Flyout { Content = DetailsPanel(repo, state.Info) };
        header.Children.Add(info);
        header.Children.Add(StatusStyle.Badge(status));
        if (state.Phase is { } phase) header.Children.Add(Ui.Caption(phase.DisplayName()));
        else if (!repo.AutoSyncEnabled) header.Children.Add(Ui.Caption(L.T("自动同步已关闭", "Auto Sync is off")));
        else if (repo.PausedForConflict) header.Children.Add(Ui.Text(L.T("因冲突暂停", "Paused for a conflict"), 12, brush: Ui.Orange));

        autoSync.IsOn = repo.AutoSyncEnabled;
        syncNow.IsEnabled = !state.IsSyncing && model.Git != null;
        syncNow.Content = state.IsSyncing
            ? Ui.Row(6, new ProgressRing { Width = 14, Height = 14, IsActive = true }, new TextBlock { Text = L.T("同步中…", "Syncing…") })
            : Ui.Label(Glyph.Sync, L.T("立即同步", "Sync Now"));

        UpdateBanners(repo, state);
        UpdateCards(repo, state);
        updating = false;
    }

    // MARK: Header details

    UIElement DetailsPanel(RepositoryConfig repo, RepositoryInfo? info)
    {
        var panel = Ui.Column(8, Ui.Text(L.T("详细信息", "Details"), 14, FontWeights.SemiBold));
        void Line(string label, string? value)
        {
            if (string.IsNullOrEmpty(value)) return;
            var link = new HyperlinkButton { Content = new TextBlock { Text = value, TextWrapping = TextWrapping.Wrap, MaxWidth = 420 }, Padding = new Thickness(0) };
            link.Click += (_, _) => { Shell.CopyText(value); link.Content = new TextBlock { Text = L.T("已复制", "Copied") }; };
            panel.Children.Add(Ui.Column(2, Ui.Caption(label), link));
        }
        Line(L.T("本地路径", "Folder"), repo.Path);
        Line(L.T("远程地址", "Remote"), info?.RemoteUrl ?? repo.KnownRemote);
        Line(L.T("分支", "Branch"), info?.Branch);
        Line(L.T("跟踪分支", "Upstream"), info?.Upstream);
        panel.Children.Add(Ui.Caption(L.T("点击路径或远程地址即可复制。", "Click the path or remote URL to copy it.")));
        return panel;
    }

    // MARK: Problems

    void UpdateBanners(RepositoryConfig repo, RepoRuntime state)
    {
        banners.Children.Clear();
        if (repo.LastStatus == SyncStatus.Conflict && repo.ConflictFiles.Count > 0 && !state.IsSyncing)
        {
            var bar = new InfoBar
            {
                IsOpen = true, IsClosable = false, Severity = InfoBarSeverity.Warning,
                Title = L.T($"{repo.ConflictFiles.Count} 个文件同时在本机和 GitHub 上被修改", $"{repo.ConflictFiles.Count} file(s) changed both here and on GitHub"),
                Message = L.T("两边的版本都还在：你的在本机，另一个在 GitHub。选择保留哪个（推荐「保留两者」）。", "Both versions are safe: yours here, the other on GitHub. Choose what to keep (Keep Both is recommended)."),
                ActionButton = Ui.Button(L.T("解决冲突…", "Resolve…"), () => _ = new ConflictsDialog(model, RepoId).ShowAsync(Element.XamlRoot), accent: true),
            };
            banners.Children.Add(bar);
        }
        else if (repo.LastFailure is { } failure && repo.LastStatus.IsProblem() && !state.IsSyncing)
        {
            if (failure.Kind == FailureKind.FolderMissing)
            {
                banners.Children.Add(MissingFolderBar(repo, state));
            }
            else
            {
                var buttons = Ui.Row(8, Ui.Button(L.T("详情", "Details"), () => _ = ErrorDetailDialog.ShowAsync(Element.XamlRoot, failure.ToFailure())));
                if (failure.Kind == FailureKind.Authentication) buttons.Children.Add(Ui.Button(L.T("登录 GitHub", "Sign In"), () => SettingsWindow.Show(model)));
                if (state.Info?.InProgressOperation is { } op)
                    buttons.Children.Add(Ui.Button(L.T("中止操作…", "Abort…"), () => _ = ConfirmAbort(op)));
                banners.Children.Add(new InfoBar
                {
                    IsOpen = true, IsClosable = false,
                    Severity = repo.LastStatus == SyncStatus.NetworkUnavailable ? InfoBarSeverity.Informational : InfoBarSeverity.Error,
                    Title = failure.Message, Message = failure.Suggestion, ActionButton = null, Content = buttons,
                });
            }
        }
        foreach (var warning in state.Warnings.Take(5))
            banners.Children.Add(Ui.Row(6, Ui.Icon(Glyph.Warning, 12, Ui.Orange), Ui.Text(warning, 12, brush: Ui.Orange, wrap: true)));
    }

    InfoBar MissingFolderBar(RepositoryConfig repo, RepoRuntime state)
    {
        var recycled = state.RecycledPath != null;
        var buttons = Ui.Row(8);
        if (recycled) buttons.Children.Add(Ui.Button(L.T("放回原处", "Put Back"), () => _ = model.PutBackFromRecycleBinAsync(RepoId), accent: true));
        if (state.Downloading)
        {
            buttons.Children.Add(Ui.Row(6, new ProgressRing { Width = 14, Height = 14, IsActive = true }, Ui.Caption(L.T("正在从 GitHub 下载…", "Downloading from GitHub…"))));
        }
        else
        {
            var download = new SplitButton { Content = Ui.Label(Glyph.Download, L.T("从 GitHub 重新下载", "Download Again from GitHub")) };
            download.Click += (_, _) => _ = model.RedownloadAsync(RepoId);
            var menu = new MenuFlyout();
            menu.Items.Add(Ui.MenuItem(L.T("下载到原来的位置", "Download to Original Location"), () => _ = model.RedownloadAsync(RepoId)));
            menu.Items.Add(Ui.MenuItem(L.T("下载到其他位置…", "Download to Another Location…"), () => _ = DownloadElsewhere(repo)));
            download.Flyout = menu;
            buttons.Children.Add(download);
            buttons.Children.Add(Ui.Button(L.T("重新定位…", "Relocate…"), () => _ = Relocate(repo)));
            buttons.Children.Add(Ui.Button(L.T("从列表移除…", "Remove from List…"), () => _ = ConfirmRemove(repo)));
        }
        return new InfoBar
        {
            IsOpen = true, IsClosable = false, Severity = InfoBarSeverity.Error,
            Title = recycled ? L.T($"「{repo.DisplayName}」在回收站中", $"“{repo.DisplayName}” is in the Recycle Bin")
                             : L.T($"找不到文件夹「{repo.DisplayName}」", $"The folder “{repo.DisplayName}” can't be found"),
            Message = recycled ? L.T("放回原处后会继续同步。", "Put it back to keep syncing.")
                               : L.T($"原来的位置：{repo.Path}。如果移动过它，选出新位置后会继续同步；如果已经删除，可以从 GitHub 重新下载。设置和历史都保留。",
                                     $"It was at {repo.Path}. If you moved it, choose its new place; if it was deleted, download it again from GitHub. Settings and history are kept."),
            Content = buttons,
        };
    }

    async Task<string?> PickFolder(string title)
    {
        var picker = new Windows.Storage.Pickers.FolderPicker { CommitButtonText = title };
        picker.FileTypeFilter.Add("*");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WindowHandle());
        return (await picker.PickSingleFolderAsync())?.Path;
    }

    nint WindowHandle() => Element.XamlRoot?.ContentIslandEnvironment?.AppWindowId is { } windowId
        ? Microsoft.UI.Win32Interop.GetWindowFromWindowId(windowId) : 0;

    async Task Relocate(RepositoryConfig repo)
    {
        if (await PickFolder(L.T("使用这个文件夹", "Use This Folder")) is not { } folder) return;
        if (await model.RelocateAsync(RepoId, folder) is { } problem) await Ui.Inform(Element.XamlRoot, L.T("无法使用这个文件夹", "Can't Use This Folder"), problem);
    }

    async Task DownloadElsewhere(RepositoryConfig repo)
    {
        if (await PickFolder(L.T("下载到这里", "Download Here")) is not { } parent) return;
        await model.RedownloadAsync(RepoId, Path.Combine(parent, Path.GetFileName(repo.Path.TrimEnd('\\', '/'))));
    }

    async Task ConfirmRemove(RepositoryConfig repo)
    {
        if (await Ui.Ask(Element.XamlRoot, L.T($"从列表移除「{repo.DisplayName}」？", $"Remove “{repo.DisplayName}” from the list?"),
                         L.T("只会从 GitSync 中移除，不会删除本地文件，也不会影响 GitHub 上的仓库。", "It's only removed from GitSync; the folder and the GitHub repository stay."),
                         L.T("移除", "Remove"), destructive: true) == ContentDialogResult.Primary)
            model.RemoveRepository(RepoId);
    }

    async Task ConfirmAbort(InProgressOperation op)
    {
        if (await Ui.Ask(Element.XamlRoot, L.T($"中止未完成的 {op.DisplayName()} 操作？", $"Abort the unfinished {op.DisplayName()}?"),
                         L.T($"将执行 git {op.GitCommand()} --abort，仓库回到该操作开始之前的状态。该操作中尚未提交的冲突解决内容会丢失；已提交的内容不受影响。",
                             $"Runs git {op.GitCommand()} --abort and returns to the state before it started. Unsaved conflict resolutions from it are lost; commits are kept."),
                         L.T("中止操作", "Abort"), destructive: true) == ContentDialogResult.Primary)
            await model.AbortInProgressOperationAsync(RepoId);
    }

    // MARK: Cards

    void UpdateCards(RepositoryConfig repo, RepoRuntime state)
    {
        cards.Children.Clear();
        var last = Card(L.T("上次同步", "Last Sync"), repo.LastSyncAt is { } at ? Ui.Relative(at) : L.T("从未成功同步", "Never"),
                        Ui.Row(6, Ui.Caption(repo.LastMessage ?? (repo.LastSyncAt is { } d ? Ui.Date(d) : "")),
                               FlyoutLink(L.T("同步记录", "Activity"), () => RecentActivity(repo))));
        var info = state.Info;
        var pendingValue = info == null ? "—" : info.RemoteUrl == null ? L.T("未关联 GitHub", "Not on GitHub")
                         : info.ChangedFiles > 0 ? L.T($"{info.ChangedFiles} 个未同步修改", $"{info.ChangedFiles} unsynced changes") : L.T("无未同步修改", "All synced");
        var pendingDetail = Ui.Row(6, Ui.Caption(info?.RemoteUrl == null ? "" : L.T($"待上传 {info.Ahead} · 待下载 {info.Behind}", $"To upload {info.Ahead} · to download {info.Behind}")));
        if (info?.ChangedFiles > 0) pendingDetail.Children.Add(FlyoutLink(L.T("查看", "View"), () => new PendingChangesPanel(model, RepoId).Element));
        var pending = Card(L.T("待同步", "Pending"), pendingValue, pendingDetail);
        var usage = state.Usage;
        var spaceValue = usage != null ? Ui.Bytes(usage.FileBytes) : state.MeasuringUsage ? L.T("正在计算…", "Measuring…") : "—";
        var spaceDetail = Ui.Row(6, Ui.Caption(usage != null ? L.T($"历史 {Ui.Bytes(usage.HistoryBytes)}", $"History {Ui.Bytes(usage.HistoryBytes)}") : ""),
                                 Ui.Link(L.T("详情", "Details"), () => _ = new StorageDialog(model, RepoId).ShowAsync(Element.XamlRoot)));
        var space = Card(L.T("空间", "Space"), spaceValue, spaceDetail,
                         usage?.Level switch { UsageLevel.Large => Ui.Orange, UsageLevel.VeryLarge => Ui.Red, _ => null });
        cards.Children.Add(last.At(0, 0));
        cards.Children.Add(pending.At(0, 1));
        cards.Children.Add(space.At(0, 2));
    }

    static Border Card(string title, string value, UIElement detail, Brush? valueBrush = null)
    {
        var card = Ui.Card(Ui.Column(2, Ui.Caption(title), Ui.Text(value, 15, FontWeights.SemiBold, valueBrush), detail), new Thickness(12, 6, 12, 6));
        card.HorizontalAlignment = HorizontalAlignment.Stretch;
        return card;
    }

    static HyperlinkButton FlyoutLink(string text, Func<UIElement> content)
    {
        var link = new HyperlinkButton { Content = text, Padding = new Thickness(0), FontSize = 12 };
        var flyout = new Flyout();
        flyout.Opening += (_, _) => flyout.Content = content();
        link.Click += (_, _) => flyout.ShowAt(link);
        return link;
    }

    UIElement RecentActivity(RepositoryConfig repo)
    {
        var panel = Ui.Column(4);
        var header = Ui.Grid("*,auto");
        header.Children.Add(Ui.Text(L.T("最近同步记录", "Recent Activity"), 14, FontWeights.SemiBold).At(0, 0));
        header.Children.Add(Ui.Link(L.T("查看全部日志", "All Logs"), () => LogsWindow.Show(model)).At(0, 1));
        panel.Children.Add(header);
        var entries = model.Logs.Where(e => e.RepositoryId == repo.Id).Take(8).ToList();
        if (entries.Count == 0) panel.Children.Add(Ui.Caption(L.T("还没有记录", "Nothing yet")));
        foreach (var entry in entries)
        {
            var row = Ui.Grid("20,110,*");
            row.Children.Add(Ui.Icon(entry.Level switch { LogLevel.Success => Glyph.Check, LogLevel.Warning => Glyph.Warning, LogLevel.Error => Glyph.Error, _ => Glyph.Info }, 12,
                                     entry.Level switch { LogLevel.Success => Ui.Green, LogLevel.Warning => Ui.Orange, LogLevel.Error => Ui.Red, _ => Ui.Gray }).At(0, 0));
            row.Children.Add(Ui.Caption(Ui.Date(entry.Date)).At(0, 1));
            row.Children.Add(Ui.Text(entry.Result.Replace(repo.DisplayName + "：", "").Replace(repo.DisplayName + ": ", ""), 12, wrap: true).At(0, 2));
            panel.Children.Add(row);
        }
        panel.Width = 460;
        return panel;
    }

    // MARK: Actions

    void BuildActions()
    {
        var left = Ui.Row(8,
            Ui.Button(L.T("历史版本", "History"), () => HistoryWindow.Show(model, RepoId), Glyph.History),
            Ui.Button(L.T("资源管理器", "Explorer"), () => { if (model.Repository(RepoId) is { } r) Shell.Open(r.Path); }, Glyph.FolderOpen),
            Ui.Button("GitHub", () => { if (model.WebUrl(RepoId) is { } url) Shell.Open(url); }, Glyph.Globe));
        var more = new DropDownButton { Content = Ui.Label(Glyph.More, L.T("更多", "More")) };
        var menu = new MenuFlyout();
        menu.Opening += (_, _) =>
        {
            menu.Items.Clear();
            if (model.Repository(RepoId) is not { } repo) return;
            var info = model.State(RepoId).Info;
            if (info != null && info.RemoteUrl == null)
                menu.Items.Add(Ui.MenuItem(L.T("发布到新的 GitHub 仓库…", "Publish to a New GitHub Repository…"),
                                           () => _ = new CreateRepositoryDialog(model, repo.Path).ShowAsync(Element.XamlRoot), Glyph.Upload));
            if (info?.InProgressOperation is { } op)
                menu.Items.Add(Ui.MenuItem(L.T($"中止 {op.DisplayName()}…", $"Abort the {op.DisplayName()}…"), () => _ = ConfirmAbort(op), Glyph.Undo));
            menu.Items.Add(Ui.MenuItem(L.T("重新定位…", "Relocate…"), () => _ = Relocate(repo), Glyph.Folder));
            menu.Items.Add(new MenuFlyoutSeparator());
            menu.Items.Add(Ui.MenuItem(L.T("从列表移除…", "Remove from List…"), () => _ = ConfirmRemove(repo)));
            menu.Items.Add(Ui.MenuItem(L.T("删除…", "Delete…"), () => _ = new DeleteRepositoryDialog(model, RepoId).ShowAsync(Element.XamlRoot), Glyph.Delete));
        };
        more.Flyout = menu;
        actions.Children.Add(left.At(0, 0));
        actions.Children.Add(more.At(0, 2));
    }
}

/// <summary>Local changes not on GitHub yet; edited and deleted files can be put back to GitHub's version.</summary>
sealed class PendingChangesPanel
{
    readonly AppModel model;
    readonly Guid id;
    public StackPanel Element { get; } = new() { Spacing = 8, Width = 460 };
    readonly StackPanel listPanel = new() { Spacing = 2 };

    public PendingChangesPanel(AppModel model, Guid id)
    {
        this.model = model;
        this.id = id;
        Element.Children.Add(Ui.Text(L.T("未同步的修改", "Unsynced Changes"), 14, FontWeights.SemiBold));
        Element.Children.Add(new ScrollViewer { Content = listPanel, MaxHeight = 320 });
        Element.Children.Add(Ui.Caption(L.T("还原会丢弃本机还没同步的修改，换回 GitHub 上现在的内容；丢弃的内容会在本机保留一份备份。",
                                            "Reverting discards changes not synced yet and brings back what's on GitHub now. A backup is kept on this computer."), wrap: true));
        _ = Load();
    }

    async Task Load()
    {
        var entries = await model.PendingChangesAsync(id);
        listPanel.Children.Clear();
        if (entries.Count == 0) { listPanel.Children.Add(Ui.Caption(L.T("没有未同步的修改", "No unsynced changes"))); return; }
        var revertible = entries.Where(e => !e.IsUntracked).Select(e => e.Path).ToList();
        if (revertible.Count > 1)
            Element.Children.Insert(1, Ui.Button(L.T("全部还原为云端版本…", "Revert All to GitHub Version…"), () => _ = Confirm(revertible)));
        foreach (var entry in entries)
        {
            var (label, color) = entry.IsUntracked ? (L.T("新增", "New"), Ui.Green) : entry.IsDeletion ? (L.T("已删除", "Deleted"), Ui.Red) : (L.T("已修改", "Edited"), Ui.Orange);
            var row = Ui.Grid("64,*,auto");
            row.Children.Add(Ui.Badge(label, color).At(0, 0));
            row.Children.Add(Ui.Text(entry.Path, 12).Tooltip(entry.Path).At(0, 1));
            row.Children.Add((entry.IsUntracked ? (FrameworkElement)Ui.Caption(L.T("只在本机", "Only here"))
                                                : Ui.Button(L.T("还原", "Revert"), () => _ = Confirm([entry.Path]))).At(0, 2));
            listPanel.Children.Add(row);
        }
    }

    async Task Confirm(List<string> paths)
    {
        var title = paths.Count == 1 ? L.T($"将「{Path.GetFileName(paths[0])}」还原为 GitHub 上的版本？", $"Revert “{Path.GetFileName(paths[0])}” to its GitHub version?")
                                     : L.T($"将 {paths.Count} 个文件还原为 GitHub 上的版本？", $"Revert {paths.Count} files to their GitHub version?");
        if (await Ui.Ask(Element.XamlRoot, title, L.T("本机还没同步的修改会被丢弃，丢弃的内容会在本机保留一份备份。", "Changes not synced yet are discarded; a backup is kept on this computer."),
                         L.T("还原", "Revert"), destructive: true) == ContentDialogResult.Primary)
            await model.RevertToCloudAsync(id, paths);
    }
}
