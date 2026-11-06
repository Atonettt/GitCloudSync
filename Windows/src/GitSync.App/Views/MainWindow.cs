using System.Collections.ObjectModel;
using GitSync.App.Services;
using GitSync.Core;
using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Ellipse = Microsoft.UI.Xaml.Shapes.Ellipse;
using Path = System.IO.Path;
using Windows.ApplicationModel.DataTransfer;
using Windows.Graphics;
using Windows.Storage;

namespace GitSync.App.Views;

/// <summary>
/// The main window: every repository in a sidebar, the selected one's page beside it, and the
/// global actions in the toolbar. Folders can be dragged in from File Explorer.
/// </summary>
public sealed class MainWindow : Window
{
    readonly AppModel model;
    readonly ObservableCollection<ListViewItem> rows = [];
    readonly Dictionary<Guid, SidebarRow> rowViews = [];
    readonly ListView list = new() { SelectionMode = ListViewSelectionMode.Single, Padding = new Thickness(4, 0, 4, 0) };
    readonly TextBox search = new() { PlaceholderText = L.T("搜索仓库", "Search repositories") };
    readonly ContentControl detailHost = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch };
    readonly StackPanel footer = new() { Spacing = 8, Padding = new Thickness(12, 8, 12, 12) };
    readonly Grid root;
    Guid? selected;
    string filter = "all";
    RepoDetailView? detail;

    public MainWindow(AppModel model)
    {
        this.model = model;
        Title = "GitSync";
        SystemBackdrop = new Microsoft.UI.Xaml.Media.MicaBackdrop();
        ExtendsContentIntoTitleBar = true;
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "GitSync.ico"));
        RestoreBounds();

        var titleBar = Ui.Row(10, new Image { Source = new Microsoft.UI.Xaml.Media.Imaging.BitmapImage(new Uri(Path.Combine(AppContext.BaseDirectory, "Assets", "GitSync.png"))), Width = 18, Height = 18 },
                              Ui.Text("GitSync", 12));
        titleBar.Margin = new Thickness(14, 0, 0, 0);
        titleBar.Height = 34;
        var titleArea = new Grid { Height = 34, Background = new SolidColorBrush(Colors.Transparent) };
        titleArea.Children.Add(titleBar);
        SetTitleBar(titleArea);

        root = Ui.Grid("280,*", "auto,*");
        root.Children.Add(titleArea.At(0, 0, columnSpan: 2));
        root.Children.Add(BuildSidebar().At(1, 0));
        root.Children.Add(BuildContent().At(1, 1));
        root.AllowDrop = true;
        root.DragOver += OnDragOver;
        root.Drop += OnDrop;
        Content = root;

        model.Changed += OnModelChanged;
        model.SelectRequested += id => { selected = id; Rebuild(); };
        model.ShowAlert = (title, message) => _ = Ui.Inform(root.XamlRoot, title, message);
        model.EditedDocumentFound += (id, document) => _ = AskAboutEditedDocument(id, document);
        Closed += (_, _) =>
        {
            SaveBounds();
            model.Changed -= OnModelChanged;
            model.ShowAlert = null;
        };
        Rebuild();
    }

    public void BringToFront()
    {
        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
        if (AppWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Minimized } presenter) presenter.Restore();
        Native.SetForegroundWindow(hwnd);
    }

    /// <summary>The last size and place, kept inside the screen's work area (small screens, unplugged monitors).</summary>
    void RestoreBounds()
    {
        var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        var wanted = model.Settings.WindowBounds is { Length: 4 } b && b[2] > 600 && b[3] > 400
            ? new RectInt32(b[0], b[1], b[2], b[3])
            : new RectInt32(area.X + (area.Width - 1180) / 2, area.Y + (area.Height - 780) / 2, 1180, 780);
        var width = Math.Min(wanted.Width, area.Width);
        var height = Math.Min(wanted.Height, area.Height);
        var x = Math.Clamp(wanted.X, area.X, area.X + area.Width - width);
        var y = Math.Clamp(wanted.Y, area.Y, area.Y + area.Height - height);
        AppWindow.MoveAndResize(new RectInt32(x, y, width, height));
    }

    void SaveBounds()
    {
        var p = AppWindow.Position;
        var s = AppWindow.Size;
        model.Settings.WindowBounds = [p.X, p.Y, s.Width, s.Height];
        model.Persist();
    }

    // MARK: Sidebar

    FrameworkElement BuildSidebar()
    {
        var grid = Ui.Grid(rows: "auto,auto,*,auto");
        search.Margin = new Thickness(12, 4, 12, 8);
        search.TextChanged += (_, _) => Rebuild();
        grid.Children.Add(search.At(0));

        var filterButton = new Button
        {
            Content = Ui.Icon(Glyph.Filter, 14),
            Background = new SolidColorBrush(Colors.Transparent),
            BorderThickness = new Thickness(0),
            Padding = new Thickness(6, 4, 6, 4),
            Flyout = FilterMenu(),
        }.Tooltip(L.T("筛选", "Filter"));
        var header = Ui.Grid("*,auto");
        header.Children.Add(Ui.Caption(L.T("仓库", "Repositories")).At(0, 0));
        header.Children.Add(filterButton.At(0, 1));
        header.Margin = new Thickness(16, 0, 10, 2);
        grid.Children.Add(header.At(1));

        list.ItemsSource = rows;
        list.CanReorderItems = true;
        list.AllowDrop = true;
        list.SelectionChanged += (_, _) =>
        {
            if (list.SelectedItem is ListViewItem { Tag: Guid id } && id != selected)
            {
                selected = id;
                ShowDetail();
            }
        };
        list.DragItemsCompleted += (_, _) =>
        {
            var order = rows.Select(r => (Guid)r.Tag).ToList();
            for (var index = 0; index < order.Count; index++) model.MoveRepository(order[index], index);
        };
        grid.Children.Add(list.At(2));

        var footerBorder = new Border { Child = footer, BorderBrush = Ui.Divider, BorderThickness = new Thickness(0, 1, 0, 0), Margin = new Thickness(8, 0, 8, 0) };
        grid.Children.Add(footerBorder.At(3));
        return new Border { Child = grid, BorderBrush = Ui.Divider, BorderThickness = new Thickness(0, 0, 1, 0) };
    }

    MenuFlyout FilterMenu()
    {
        var menu = new MenuFlyout();
        void Add(string key, string text)
        {
            var item = new RadioMenuFlyoutItem { Text = text, GroupName = "filter", IsChecked = filter == key };
            item.Click += (_, _) => { filter = key; Rebuild(); };
            menu.Items.Add(item);
        }
        Add("all", L.T("全部", "All"));
        Add("on", L.T("自动同步中", "Auto Sync On"));
        Add("off", L.T("已暂停", "Paused"));
        Add("attention", L.T("需要处理", "Needs Attention"));
        return menu;
    }

    List<RepositoryConfig> Visible()
    {
        var query = search.Text.Trim();
        return model.Repositories.Where(r =>
            (query.Length == 0 || r.DisplayName.Contains(query, StringComparison.CurrentCultureIgnoreCase) || r.Path.Contains(query, StringComparison.CurrentCultureIgnoreCase)) &&
            filter switch
            {
                "on" => r.AutoSyncEnabled,
                "off" => !r.AutoSyncEnabled,
                "attention" => r.LastStatus.IsProblem(),
                _ => true,
            }).ToList();
    }

    void Rebuild()
    {
        var visible = Visible();
        list.CanReorderItems = filter == "all" && search.Text.Trim().Length == 0;
        if (!visible.Select(r => r.Id).SequenceEqual(rows.Select(r => (Guid)r.Tag)))
        {
            rows.Clear();
            foreach (var repo in visible)
            {
                if (!rowViews.TryGetValue(repo.Id, out var view)) rowViews[repo.Id] = view = new SidebarRow(model, repo.Id);
                rows.Add(new ListViewItem { Content = view.Element, Tag = repo.Id, Padding = new Thickness(8, 6, 8, 6) });
            }
        }
        foreach (var view in rowViews.Values) view.Update();
        if (selected == null || visible.All(r => r.Id != selected)) selected = visible.FirstOrDefault()?.Id ?? (visible.Count == 0 ? null : selected);
        list.SelectedItem = rows.FirstOrDefault(r => (Guid)r.Tag == selected);
        UpdateFooter();
        ShowDetail();
    }

    void OnModelChanged(Guid? id)
    {
        if (id is { } repoId && rowViews.TryGetValue(repoId, out var view) && model.Repository(repoId) != null)
        {
            view.Update();
            UpdateFooter();
            detail?.Update();
        }
        else
        {
            foreach (var removed in rowViews.Keys.Where(k => model.Repository(k) == null).ToList()) rowViews.Remove(removed);
            Rebuild();
        }
    }

    void UpdateFooter()
    {
        footer.Children.Clear();
        footer.Children.Add(new AccountCard(model).Element);

        var running = model.AutoSyncCount > 0;
        var status = Ui.Grid("36,*");
        status.Children.Add(Ui.Icon(running ? Glyph.Sync : Glyph.Pause, 15, running ? (model.IsOnline ? Ui.Green : Ui.Gray) : Ui.Secondary).At(0, 0));
        var lines = Ui.Column(0, Ui.Text(model.OverallStatusText, 12),
                              Ui.Caption(running && model.NextSyncDate is { } next
                                  ? L.T($"每 {model.Settings.IntervalMinutes} 分钟 · 下次 {next:HH:mm}", $"Every {model.Settings.IntervalMinutes} min · next {next:HH:mm}")
                                  : L.T($"每 {model.Settings.IntervalMinutes} 分钟", $"Every {model.Settings.IntervalMinutes} min")));
        status.Children.Add(lines.At(0, 1));
        footer.Children.Add(status);

        var add = new SplitButton
        {
            Content = Ui.Label(Glyph.Add, L.T("添加仓库", "Add Repository")),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            Flyout = AddMenu(),
            IsEnabled = model.Git != null,
        };
        add.Click += (_, _) => _ = ChooseFolders();
        footer.Children.Add(add);
    }

    MenuFlyout AddMenu()
    {
        var menu = new MenuFlyout();
        menu.Items.Add(Ui.MenuItem(L.T("添加本地文件夹…", "Add Local Folder…"), () => _ = ChooseFolders(), Glyph.Folder));
        var signedIn = model.Auth.State.IsUsable;
        menu.Items.Add(Ui.MenuItem(signedIn ? L.T("从 GitHub 下载…", "Download from GitHub…") : L.T("从 GitHub 下载…（需要先登录）", "Download from GitHub… (sign in first)"),
                                   () => _ = new GitHubRepositoriesDialog(model).ShowAsync(root.XamlRoot), Glyph.Download, signedIn));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(Ui.MenuItem(L.T("管理 GitHub 上的仓库…", "Manage Repositories on GitHub…"),
                                   () => _ = new GitHubRepositoriesDialog(model).ShowAsync(root.XamlRoot), Glyph.Cloud, signedIn));
        return menu;
    }

    // MARK: Content

    FrameworkElement BuildContent()
    {
        var grid = Ui.Grid(rows: "auto,*");
        var syncAll = new SplitButton
        {
            Content = Ui.Label(Glyph.Sync, L.T("全部同步", "Sync All")),
            Flyout = SyncMenu(),
        }.Tooltip(L.T("点击马上同步所有仓库（包括自动同步关闭的）；点箭头设置同步间隔", "Sync every repository now; the arrow sets the interval"));
        syncAll.Click += (_, _) => model.SyncAll(SyncTrigger.ManualAll);
        var toolbar = Ui.Row(4, syncAll,
                             Ui.IconButton(Glyph.Logs, L.T("日志", "Logs"), () => LogsWindow.Show(model)),
                             Ui.IconButton(Glyph.Settings, L.T("设置", "Settings"), () => SettingsWindow.Show(model)));
        toolbar.HorizontalAlignment = HorizontalAlignment.Right;
        toolbar.Margin = new Thickness(0, 0, 16, 4);
        grid.Children.Add(toolbar.At(0));
        grid.Children.Add(detailHost.At(1));
        return grid;
    }

    MenuFlyout SyncMenu()
    {
        var menu = new MenuFlyout();
        menu.Opening += (_, _) =>
        {
            menu.Items.Clear();
            menu.Items.Add(new MenuFlyoutItem { Text = L.T("同步间隔", "Sync interval"), IsEnabled = false });
            foreach (var minutes in AppSettings.PresetIntervals)
            {
                var item = new RadioMenuFlyoutItem
                {
                    Text = minutes == 60 ? L.T("60 分钟（1 小时）", "60 minutes (1 hour)") : L.T($"{minutes} 分钟", $"{minutes} minutes"),
                    GroupName = "interval",
                    IsChecked = model.Settings.IntervalMinutes == minutes,
                };
                item.Click += (_, _) => model.SetInterval(minutes);
                menu.Items.Add(item);
            }
            if (!AppSettings.PresetIntervals.Contains(model.Settings.IntervalMinutes))
                menu.Items.Add(new RadioMenuFlyoutItem { Text = L.T($"自定义：{model.Settings.IntervalMinutes} 分钟", $"Custom: {model.Settings.IntervalMinutes} minutes"), IsChecked = true, GroupName = "interval" });
            menu.Items.Add(Ui.MenuItem(L.T("自定义…", "Custom…"), () => _ = CustomInterval()));
            menu.Items.Add(new MenuFlyoutSeparator());
            if (model.AutoSyncCount > 0) menu.Items.Add(Ui.MenuItem(L.T("全部暂停自动同步", "Pause Auto Sync for All"), () => model.SetAutoSyncForAll(false), Glyph.Pause));
            if (model.AutoSyncCount < model.Repositories.Count) menu.Items.Add(Ui.MenuItem(L.T("全部开启自动同步", "Turn On Auto Sync for All"), () => model.SetAutoSyncForAll(true), Glyph.Play));
        };
        return menu;
    }

    async Task CustomInterval()
    {
        var box = new NumberBox { Value = model.Settings.IntervalMinutes, Minimum = 1, Maximum = 1440, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Inline, Header = L.T("分钟", "Minutes") };
        var dialog = new ContentDialog
        {
            XamlRoot = root.XamlRoot,
            Title = L.T("自定义同步间隔", "Custom Sync Interval"),
            Content = box,
            PrimaryButtonText = L.T("应用", "Apply"),
            CloseButtonText = L.T("取消", "Cancel"),
            DefaultButton = ContentDialogButton.Primary,
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary && !double.IsNaN(box.Value)) model.SetInterval((int)box.Value);
    }

    void ShowDetail()
    {
        if (model.Repositories.Count == 0)
        {
            detail = null;
            detailHost.Content = EmptyState();
            return;
        }
        if (selected is not { } id || model.Repository(id) == null)
        {
            detail = null;
            detailHost.Content = Ui.Caption(L.T("没有符合条件的仓库", "No matching repositories"));
            return;
        }
        if (detail?.RepoId == id) { detail.Update(); return; }
        detail = new RepoDetailView(model, id);
        detailHost.Content = detail.Element;
    }

    UIElement EmptyState()
    {
        var column = Ui.Column(12,
            new Image { Source = new Microsoft.UI.Xaml.Media.Imaging.BitmapImage(new Uri(Path.Combine(AppContext.BaseDirectory, "Assets", "GitSync.png"))), Width = 96, Height = 96 },
            Ui.Title(L.T("把文件夹拖进来，开始同步", "Drag a folder in to start syncing"), 22),
            Ui.Text(L.T("GitSync 会在你的 GitHub 账号里创建一个同名的私有仓库，然后自动双向同步，保留每个版本。",
                        "GitSync creates a private repository with the same name in your GitHub account, then syncs both ways and keeps every version."),
                    wrap: true, brush: Ui.Secondary),
            Ui.Row(8, Ui.Button(L.T("添加文件夹…", "Add Folder…"), () => _ = ChooseFolders(), Glyph.Folder, accent: true),
                      Ui.Button(L.T("从 GitHub 下载…", "Download from GitHub…"), () => _ = new GitHubRepositoriesDialog(model).ShowAsync(root.XamlRoot), Glyph.Download)));
        foreach (var child in column.Children) if (child is FrameworkElement element) element.HorizontalAlignment = HorizontalAlignment.Center;
        column.MaxWidth = 520;
        column.VerticalAlignment = VerticalAlignment.Center;
        column.HorizontalAlignment = HorizontalAlignment.Center;
        if (model.GitProblem is { } problem)
            column.Children.Insert(0, new InfoBar { IsOpen = true, Severity = InfoBarSeverity.Error, IsClosable = false, Title = L.T("未找到可用的 Git", "Git wasn't found"), Message = problem });
        return column;
    }

    // MARK: Adding folders

    async Task ChooseFolders()
    {
        var picker = new Windows.Storage.Pickers.FolderPicker();
        picker.FileTypeFilter.Add("*");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        if (await picker.PickSingleFolderAsync() is { } folder) await AddFolders([folder.Path]);
    }

    void OnDragOver(object sender, DragEventArgs e)
    {
        if (!e.DataView.Contains(StandardDataFormats.StorageItems)) return;
        e.AcceptedOperation = DataPackageOperation.Link;
        e.DragUIOverride.Caption = L.T("添加到 GitSync", "Add to GitSync");
    }

    async void OnDrop(object sender, DragEventArgs e)
    {
        if (!e.DataView.Contains(StandardDataFormats.StorageItems)) return;
        var items = await e.DataView.GetStorageItemsAsync();
        var folders = items.OfType<StorageFolder>().Select(f => f.Path).ToList();
        if (folders.Count > 0) await AddFolders(folders);
    }

    public async Task AddFolders(IReadOnlyList<string> folders)
    {
        var (needCreation, problems) = await model.AddRepositoriesAsync(folders);
        foreach (var folder in needCreation) await new CreateRepositoryDialog(model, folder).ShowAsync(root.XamlRoot);
        if (problems.Count > 0) await Ui.Inform(root.XamlRoot, L.T("添加仓库", "Add Repository"), string.Join("\n\n", problems));
    }

    async Task AskAboutEditedDocument(Guid id, OfficeDocuments.OpenDocument document)
    {
        var answer = await Ui.Ask(root.XamlRoot,
            L.T($"「{document.FileName}」在 {document.App.Name} 里有未保存的修改", $"“{document.FileName}” has unsaved changes in {document.App.Name}"),
            L.T($"GitHub 上的新版本刚刚同步到这台电脑。如果直接在 {document.App.Name} 里保存，会用你打开时的旧内容覆盖新版本。",
                $"A newer version from GitHub was just synced. Saving in {document.App.Name} now would overwrite it with the content you opened."),
            L.T("两个都保留", "Keep Both"), L.T("用云端版本", "Use GitHub Version"), L.T("稍后处理", "Later"));
        var stage = L.T("刷新打开的文档", "Open documents");
        if (answer == ContentDialogResult.Primary)
        {
            var copy = OfficeDocuments.CopyPath(document.Path);
            if (OfficeDocuments.SaveCopyAndReopen(document, copy) is { } problem)
            {
                model.Log(id, stage, LogLevel.Error, problem);
                await Ui.Inform(root.XamlRoot, L.T("无法另存你的修改", "Couldn't Save Your Changes"),
                                L.T($"请在 {document.App.Name} 中用「文件 › 另存为」把修改存成另一个文件，再重新打开「{document.FileName}」。",
                                    $"In {document.App.Name}, use File › Save As to save your changes as another file, then open “{document.FileName}” again."));
            }
            else model.Log(id, stage, LogLevel.Success, L.T($"你的修改已另存为「{Path.GetFileName(copy)}」，并打开了云端版本", $"Your changes were saved as “{Path.GetFileName(copy)}”; the GitHub version is open"));
        }
        else if (answer == ContentDialogResult.Secondary)
        {
            if (OfficeDocuments.Reopen(document) is { } problem) model.Log(id, stage, LogLevel.Error, problem);
            else model.Log(id, stage, LogLevel.Warning, L.T($"已丢弃 {document.App.Name} 中未保存的修改，打开了云端版本「{document.FileName}」", $"Discarded unsaved changes and opened the GitHub version of “{document.FileName}”"));
        }
    }
}

/// <summary>One repository in the sidebar: status, name, last sync and the Auto Sync switch.</summary>
sealed class SidebarRow
{
    readonly AppModel model;
    readonly Guid id;
    readonly FontIcon statusIcon = Ui.Icon(Glyph.Check, 16);
    readonly ProgressRing ring = new() { Width = 16, Height = 16, IsActive = true };
    readonly TextBlock name = Ui.Text("", 14);
    readonly TextBlock subtitle = Ui.Caption("");
    readonly Button toggle;
    public Grid Element { get; } = Ui.Grid("26,*,auto");

    public SidebarRow(AppModel model, Guid id)
    {
        this.model = model;
        this.id = id;
        var statusHost = new Grid();
        statusHost.Children.Add(statusIcon);
        statusHost.Children.Add(ring);
        Element.Children.Add(statusHost.At(0, 0));
        Element.Children.Add(Ui.Column(0, name, subtitle).At(0, 1));
        toggle = Ui.IconButton(Glyph.Sync, "", () =>
        {
            if (model.Repository(id) is { } repo) model.SetAutoSync(id, !repo.AutoSyncEnabled);
        }, 12);
        Element.Children.Add(toggle.At(0, 2));
    }

    public void Update()
    {
        if (model.Repository(id) is not { } repo) return;
        var state = model.State(id);
        var status = model.DisplayStatus(repo);
        ring.Visibility = status.IsActive() ? Visibility.Visible : Visibility.Collapsed;
        statusIcon.Visibility = status.IsActive() ? Visibility.Collapsed : Visibility.Visible;
        statusIcon.Glyph = StatusStyle.Glyph(status);
        statusIcon.Foreground = StatusStyle.Brush(status);
        name.Text = repo.DisplayName;
        name.Foreground = repo.AutoSyncEnabled ? (Brush)Application.Current.Resources["TextFillColorPrimaryBrush"] : Ui.Secondary;
        subtitle.Text = status.IsActive() ? state.Phase?.DisplayName() ?? status.DisplayName()
                      : status.IsProblem() ? repo.LastMessage ?? status.DisplayName()
                      : repo.LastSyncAt is { } at ? L.T($"{Ui.Relative(at)}同步", $"Synced {Ui.Relative(at)}") : L.T("从未成功同步", "Never synced");
        subtitle.Foreground = status.IsProblem() ? StatusStyle.Brush(status) : Ui.Secondary;
        toggle.Content = Ui.Icon(repo.AutoSyncEnabled ? Glyph.Sync : Glyph.Pause, 12, repo.AutoSyncEnabled ? Ui.Green : Ui.Secondary);
        ToolTipService.SetToolTip(toggle, repo.AutoSyncEnabled ? L.T("自动同步中，点击暂停", "Auto Sync is on. Click to pause")
                                                               : L.T("自动同步已暂停，点击开启", "Auto Sync is paused. Click to turn on"));
    }
}

/// <summary>Icons and colours for sync states.</summary>
public static class StatusStyle
{
    public static string Glyph(SyncStatus status) => status switch
    {
        SyncStatus.Success or SyncStatus.NoChanges => Views.Glyph.Check,
        SyncStatus.Conflict => Views.Glyph.Merge,
        SyncStatus.NeedsAuth => Views.Glyph.Lock,
        SyncStatus.NetworkUnavailable => Views.Glyph.Cloud,
        SyncStatus.Failed => Views.Glyph.Error,
        _ => Views.Glyph.Clock,
    };

    public static SolidColorBrush Brush(SyncStatus status) => status switch
    {
        SyncStatus.Success or SyncStatus.NoChanges => Ui.Green,
        SyncStatus.Conflict or SyncStatus.NeedsAuth => Ui.Orange,
        SyncStatus.Failed => Ui.Red,
        SyncStatus.NetworkUnavailable => Ui.Gray,
        _ => Ui.Blue,
    };

    public static Border Badge(SyncStatus status) => Ui.Badge(status.DisplayName(), Brush(status));
}

/// <summary>The account at the bottom of the sidebar, like a small name card.</summary>
sealed class AccountCard(AppModel model)
{
    public UIElement Element
    {
        get
        {
            var state = model.Auth.State;
            var (title, subtitle) = state switch
            {
                AuthState.SignedIn s => (s.Login, L.T($"已通过 {AuthState.SourceName(s.Source)} 登录", $"Signed in with {AuthState.SourceName(s.Source)}")),
                AuthState.Unverified => ("GitHub", L.T("已找到凭据，暂时无法验证", "Credentials found, can't verify right now")),
                AuthState.SignedOut => (L.T("未登录 GitHub", "Not signed in to GitHub"), L.T("登录后才能同步", "Sign in to sync")),
                AuthState.Invalid i => (L.T("GitHub 登录已失效", "GitHub sign-in expired"), i.Message),
                AuthState.Checking => ("GitHub", L.T("正在检测登录状态…", "Checking sign-in…")),
                _ => ("GitHub", L.T("尚未检测", "Not checked yet")),
            };
            var icon = new Grid { Width = 28, Height = 28 };
            icon.Children.Add(new Image { Source = new Microsoft.UI.Xaml.Media.Imaging.BitmapImage(new Uri(Path.Combine(AppContext.BaseDirectory, "Assets", "GitSync.png"))), Width = 28, Height = 28 });
            icon.Children.Add(new Ellipse
            {
                Width = 9, Height = 9, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Bottom,
                Fill = state switch { AuthState.SignedIn => Ui.Green, AuthState.Unverified => Ui.Solid(Windows.UI.Color.FromArgb(255, 234, 179, 8)), AuthState.Checking or AuthState.Unknown => Ui.Gray, _ => Ui.Orange },
                Stroke = (Brush)Application.Current.Resources["SolidBackgroundFillColorBaseBrush"],
                StrokeThickness = 1.5,
                Margin = new Thickness(0, 0, -2, -2),
            });
            var grid = Ui.Grid("36,*,auto");
            grid.Children.Add(icon.At(0, 0));
            grid.Children.Add(Ui.Column(0, Ui.Text(title, 13, FontWeights.SemiBold), Ui.Caption(subtitle)).At(0, 1));
            if (!state.IsUsable && state is not AuthState.Checking)
                grid.Children.Add(Ui.Link(L.T("登录", "Sign In"), () => SettingsWindow.Show(model)).At(0, 2));
            ToolTipService.SetToolTip(grid, state.Summary);
            return grid;
        }
    }
}
