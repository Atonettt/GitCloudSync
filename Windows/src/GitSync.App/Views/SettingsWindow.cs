using GitSync.App.Services;
using GitSync.Core;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Graphics;

namespace GitSync.App.Views;

/// <summary>Settings: GitHub account, general (language, start at login), sync, notifications, Git.</summary>
public sealed class SettingsWindow : Window
{
    static SettingsWindow? open;

    public static void Show(AppModel model)
    {
        if (open == null)
        {
            open = new SettingsWindow(model);
            open.Closed += (_, _) => open = null;
        }
        open.Activate();
    }

    readonly AppModel model;
    readonly StackPanel account = new() { Spacing = 10 };

    SettingsWindow(AppModel model)
    {
        this.model = model;
        Title = L.T("GitSync 设置", "GitSync Settings");
        SystemBackdrop = new Microsoft.UI.Xaml.Media.MicaBackdrop();
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "GitSync.ico"));
        AppWindow.Resize(new SizeInt32(760, 820));

        var page = Ui.Column(16);
        page.Padding = new Thickness(28, 20, 28, 28);
        page.MaxWidth = 720;
        page.Children.Add(Section(L.T("GitHub 账户", "GitHub Account"), account));
        page.Children.Add(Section(L.T("通用", "General"), General()));
        page.Children.Add(Section(L.T("同步", "Sync"), Sync()));
        page.Children.Add(Section(L.T("通知", "Notifications"), NotificationsSection()));
        page.Children.Add(Section("Git", GitSection()));
        page.Children.Add(Ui.Caption(L.T("设置和日志保存在 ", "Settings and logs are kept in ") + StateStore.Folder, wrap: true));
        Content = new ScrollViewer { Content = page };

        RenderAccount();
        model.Changed += OnChanged;
        Closed += (_, _) => model.Changed -= OnChanged;
    }

    void OnChanged(Guid? _) => RenderAccount();

    static UIElement Section(string title, UIElement content) =>
        Ui.Column(8, Ui.Text(title, 15, FontWeights.SemiBold), Ui.Card(content, new Thickness(16, 12, 16, 12)));

    void RenderAccount()
    {
        account.Children.Clear();
        var state = model.Auth.State;
        account.Children.Add(Ui.Text(state.Summary, 14, state.IsUsable ? FontWeights.SemiBold : FontWeights.Normal));
        var buttons = Ui.Row(8);
        if (model.Git is { } git)
            buttons.Children.Add(Ui.Button(L.T("用浏览器登录…", "Sign In with Browser…"), async () =>
            {
                if (await model.Auth.SignInWithBrowserAsync(git) is { } problem) await Ui.Inform(Content.XamlRoot, L.T("登录没有完成", "Sign-In Didn't Finish"), problem);
            }, Glyph.Globe, accent: !state.IsUsable));
        buttons.Children.Add(Ui.Button(L.T("重新检测", "Check Again"), () => _ = model.Auth.RefreshAsync(model.Git), Glyph.Refresh));
        if (state is AuthState.SignedIn { Source: AuthSource.PersonalToken })
            buttons.Children.Add(Ui.Button(L.T("退出登录", "Sign Out"), () => _ = model.Auth.SignOutAsync(model.Git)));
        account.Children.Add(buttons);

        var token = new PasswordBox { PlaceholderText = L.T("或粘贴个人访问令牌（ghp_… 或 github_pat_…）", "Or paste a personal access token (ghp_… or github_pat_…)"), Width = 420 };
        var save = Ui.Button(L.T("保存令牌", "Save Token"), async () =>
        {
            if (token.Password.Trim().Length == 0) return;
            if (await model.Auth.SignInWithTokenAsync(token.Password, model.Git) is { } problem)
                await Ui.Inform(Content.XamlRoot, L.T("令牌无效", "Invalid Token"), problem);
            else token.Password = "";
        });
        account.Children.Add(Ui.Row(8, token, save));
        account.Children.Add(Ui.Row(4,
            Ui.Caption(L.T("令牌需要 repo 权限；要在 GitSync 里删除仓库，还需要 delete_repo。", "The token needs the repo scope; deleting repositories from GitSync also needs delete_repo.")),
            Ui.Link(L.T("创建令牌", "Create a token"), () => Shell.Open("https://github.com/settings/tokens/new?scopes=repo,delete_repo&description=GitSync"))));
        account.Children.Add(Ui.Caption(L.T("用浏览器登录通过 Git for Windows 自带的 Git 凭据管理器完成；也会自动使用 GitHub CLI（gh auth login）的登录。令牌保存在 Windows 凭据管理器中。",
                                            "Browser sign-in goes through Git Credential Manager (part of Git for Windows); a GitHub CLI sign-in (gh auth login) is used too. Tokens are kept in Windows Credential Manager."), wrap: true));
    }

    UIElement General()
    {
        var language = new ComboBox { Header = L.T("语言", "Language"), MinWidth = 220 };
        foreach (var (key, text) in new[] { ("system", L.T("跟随系统", "Use System Setting")), ("zh", "简体中文"), ("en", "English") })
            language.Items.Add(new ComboBoxItem { Content = text, Tag = key, IsSelected = model.Settings.Language == key });
        var note = Ui.Caption("");
        language.SelectionChanged += (_, _) =>
        {
            var value = (string)((ComboBoxItem)language.SelectedItem).Tag;
            if (value == model.Settings.Language) return;
            model.UpdateSettings(s => s.Language = value);
            note.Text = L.T("重新打开 GitSync 后生效。", "Takes effect when GitSync is opened again.");
        };
        var startup = new ToggleSwitch { Header = L.T("登录 Windows 时启动 GitSync（在通知区域运行）", "Start GitSync when signing in to Windows (runs in the notification area)"), IsOn = model.Settings.StartAtLogin };
        startup.Toggled += (_, _) => model.UpdateSettings(s => s.StartAtLogin = startup.IsOn);
        var wake = new ToggleSwitch { Header = L.T("电脑从睡眠唤醒后立即同步", "Sync right after waking from sleep"), IsOn = model.Settings.SyncOnWake };
        wake.Toggled += (_, _) => model.UpdateSettings(s => s.SyncOnWake = wake.IsOn);
        var rename = new ToggleSwitch { Header = L.T("文件夹改名时，GitHub 上的仓库跟着改名（中文转为拼音）", "Rename the GitHub repository with the folder (Chinese becomes pinyin)"), IsOn = model.Settings.RenameRemoteWithFolder };
        rename.Toggled += (_, _) => model.UpdateSettings(s => s.RenameRemoteWithFolder = rename.IsOn);
        return Ui.Column(12, language, note, startup, wake, rename,
            Ui.Caption(L.T("关闭窗口后 GitSync 会继续在通知区域（任务栏右下角）运行并同步。", "Closing the window keeps GitSync running and syncing in the notification area."), wrap: true));
    }

    UIElement Sync()
    {
        var interval = new NumberBox { Header = L.T("同步间隔（分钟）", "Sync interval (minutes)"), Value = model.Settings.IntervalMinutes, Minimum = 1, Maximum = 1440,
                                       SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Inline, Width = 220, HorizontalAlignment = HorizontalAlignment.Left };
        interval.ValueChanged += (_, _) => { if (!double.IsNaN(interval.Value)) model.SetInterval((int)interval.Value); };
        var concurrent = new NumberBox { Header = L.T("同时同步的仓库数", "Repositories synced at once"), Value = model.Settings.MaxConcurrentSyncs, Minimum = 1, Maximum = 8,
                                         SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Inline, Width = 220, HorizontalAlignment = HorizontalAlignment.Left };
        concurrent.ValueChanged += (_, _) => { if (!double.IsNaN(concurrent.Value)) model.UpdateSettings(s => s.MaxConcurrentSyncs = (int)concurrent.Value); };
        var limit = new NumberBox { Header = L.T("单个文件上传上限（MB，GitHub 最大 100）", "Upload limit per file (MB; GitHub allows up to 100)"), Value = model.Settings.LargeFileLimitMB,
                                    Minimum = 1, Maximum = 100, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Inline, Width = 320, HorizontalAlignment = HorizontalAlignment.Left };
        limit.ValueChanged += (_, _) => { if (!double.IsNaN(limit.Value)) model.UpdateSettings(s => s.LargeFileLimitMB = (int)limit.Value); };
        var ignore = new TextBox { Header = L.T("不同步的文件（每行一个，支持 * 通配符）", "Files not to sync (one per line, * allowed)"), AcceptsReturn = true, Height = 160,
                                   Text = string.Join("\r\n", model.Settings.IgnorePatterns), TextWrapping = TextWrapping.NoWrap };
        ignore.LostFocus += (_, _) => model.UpdateSettings(s => s.IgnorePatterns = ignore.Text.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).ToList());
        var reset = Ui.Link(L.T("恢复默认", "Restore defaults"), () =>
        {
            ignore.Text = string.Join("\r\n", IgnoreRules.DefaultPatterns);
            model.UpdateSettings(s => s.IgnorePatterns = [.. IgnoreRules.DefaultPatterns]);
        });
        return Ui.Column(12, interval, concurrent, limit, ignore, reset,
            Ui.Caption(L.T("已经同步过的文件不受忽略规则影响（Git 的限制）。", "Files already synced aren't affected by ignore rules (a Git limitation)."), wrap: true));
    }

    UIElement NotificationsSection()
    {
        ToggleSwitch Toggle(string text, bool value, Action<AppSettings, bool> set)
        {
            var toggle = new ToggleSwitch { Header = text, IsOn = value };
            toggle.Toggled += (_, _) => model.UpdateSettings(s => set(s, toggle.IsOn));
            return toggle;
        }
        return Ui.Column(8,
            Toggle(L.T("同步失败时", "When a sync fails"), model.Settings.NotifyOnFailure, (s, v) => s.NotifyOnFailure = v),
            Toggle(L.T("出现冲突时", "When there's a conflict"), model.Settings.NotifyOnConflict, (s, v) => s.NotifyOnConflict = v),
            Toggle(L.T("GitHub 登录失效时", "When the GitHub sign-in stops working"), model.Settings.NotifyOnAuthProblem, (s, v) => s.NotifyOnAuthProblem = v),
            Toggle(L.T("每次上传或下载了内容时", "Whenever something was uploaded or downloaded"), model.Settings.NotifyOnChanges, (s, v) => s.NotifyOnChanges = v));
    }

    UIElement GitSection()
    {
        var info = Ui.Caption(model.Git is { } git ? $"{git.Version}\n{git.GitPath}" : model.GitProblem ?? "", wrap: true);
        var custom = new TextBox { Header = L.T("自定义 git.exe 路径（留空自动查找）", "Custom git.exe path (empty: find automatically)"), Text = model.Settings.CustomGitPath ?? "" };
        custom.LostFocus += (_, _) => model.UpdateSettings(s => s.CustomGitPath = custom.Text.Trim().Length == 0 ? null : custom.Text.Trim());
        var column = Ui.Column(10, info, custom);
        if (model.Git == null)
            column.Children.Insert(0, Ui.Button(L.T("下载 Git for Windows", "Download Git for Windows"), () => Shell.Open("https://git-scm.com/download/win"), Glyph.Download, accent: true));
        return column;
    }
}

/// <summary>Every sync step, with details that can be copied.</summary>
public sealed class LogsWindow : Window
{
    static LogsWindow? open;

    public static void Show(AppModel model)
    {
        if (open == null)
        {
            open = new LogsWindow(model);
            open.Closed += (_, _) => open = null;
        }
        open.Activate();
    }

    readonly AppModel model;
    readonly ListView list = new() { SelectionMode = ListViewSelectionMode.Single };
    readonly TextBlock detail = Ui.Text("", 12, wrap: true, selectable: true);
    readonly ComboBox level = new() { MinWidth = 140 };
    readonly TextBox search = new() { PlaceholderText = L.T("搜索日志", "Search logs"), Width = 260 };

    LogsWindow(AppModel model)
    {
        this.model = model;
        Title = L.T("GitSync 日志", "GitSync Logs");
        SystemBackdrop = new Microsoft.UI.Xaml.Media.MicaBackdrop();
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "GitSync.ico"));
        AppWindow.Resize(new SizeInt32(1100, 720));
        level.Items.Add(new ComboBoxItem { Content = L.T("全部级别", "All levels"), Tag = "", IsSelected = true });
        foreach (var value in Enum.GetValues<LogLevel>()) level.Items.Add(new ComboBoxItem { Content = value.DisplayName(), Tag = value.ToString() });
        level.SelectionChanged += (_, _) => Render();
        search.TextChanged += (_, _) => Render();

        var toolbar = Ui.Row(8, search, level,
            Ui.Button(L.T("复制所选", "Copy Selected"), () => { if (list.SelectedItem is ListViewItem { Tag: SyncLogEntry e }) Shell.CopyText(e.CopyText); }, Glyph.Copy),
            Ui.Button(L.T("清空…", "Clear…"), async () =>
            {
                if (await Ui.Ask(Content.XamlRoot, L.T("清空所有同步日志？", "Clear all logs?"), L.T("只清空日志，不影响任何文件。", "Only the logs are cleared; files aren't affected."),
                                 L.T("清空", "Clear"), destructive: true) == ContentDialogResult.Primary) model.ClearLogs();
            }, Glyph.Delete));
        toolbar.Padding = new Thickness(16, 12, 16, 8);
        var grid = Ui.Grid("*,1,420", "auto,*");
        grid.Children.Add(toolbar.At(0, 0, columnSpan: 3));
        grid.Children.Add(list.At(1, 0));
        grid.Children.Add(new Border { Width = 1, Background = Ui.Divider }.At(1, 1));
        grid.Children.Add(new ScrollViewer { Content = detail, Padding = new Thickness(16) }.At(1, 2));
        Content = grid;
        list.SelectionChanged += (_, _) => detail.Text = list.SelectedItem is ListViewItem { Tag: SyncLogEntry e } ? e.CopyText : "";
        model.LogsChanged += Render;
        Closed += (_, _) => model.LogsChanged -= Render;
        Render();
    }

    void Render()
    {
        var query = search.Text.Trim();
        var wanted = (level.SelectedItem as ComboBoxItem)?.Tag as string ?? "";
        list.Items.Clear();
        foreach (var entry in model.Logs.Where(e => (wanted.Length == 0 || e.Level.ToString() == wanted) &&
                                                     (query.Length == 0 || e.Result.Contains(query, StringComparison.CurrentCultureIgnoreCase) ||
                                                      e.RepositoryName.Contains(query, StringComparison.CurrentCultureIgnoreCase))).Take(1000))
        {
            var row = Ui.Grid("20,110,140,*");
            row.ColumnSpacing = 8;
            row.Children.Add(Ui.Icon(entry.Level switch { LogLevel.Success => Glyph.Check, LogLevel.Warning => Glyph.Warning, LogLevel.Error => Glyph.Error, _ => Glyph.Info }, 12,
                                     entry.Level switch { LogLevel.Success => Ui.Green, LogLevel.Warning => Ui.Orange, LogLevel.Error => Ui.Red, _ => Ui.Gray }).At(0, 0));
            row.Children.Add(Ui.Caption(Ui.Date(entry.Date)).At(0, 1));
            row.Children.Add(Ui.Text($"{entry.RepositoryName} · {entry.Stage}", 12).At(0, 2));
            row.Children.Add(Ui.Text(entry.Result, 12).At(0, 3));
            list.Items.Add(new ListViewItem { Content = row, Tag = entry, Padding = new Thickness(12, 4, 12, 4) });
        }
    }
}
