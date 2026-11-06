using System.Windows.Input;
using GitSync.Core;
using H.NotifyIcon;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;

namespace GitSync.App.Views;

public sealed class RelayCommand(Action action) : ICommand
{
    public event EventHandler? CanExecuteChanged { add { } remove { } }
    public bool CanExecute(object? parameter) => true;
    public void Execute(object? parameter) => action();
}

/// <summary>
/// The icon in the notification area. Closing the window keeps GitSync running here; a click opens
/// the window, the menu has Sync All, the Auto Sync switch and Quit.
/// </summary>
public sealed class TrayIcon : IDisposable
{
    readonly AppModel model;
    readonly TaskbarIcon icon;
    readonly MenuFlyout menu = new();

    public TrayIcon(AppModel model)
    {
        this.model = model;
        icon = new TaskbarIcon
        {
            IconSource = new BitmapImage(new Uri(Path.Combine(AppContext.BaseDirectory, "Assets", "GitSync.ico"))),
            ToolTipText = "GitSync",
            ContextMenuMode = ContextMenuMode.SecondWindow,
            NoLeftClickDelay = true,
            LeftClickCommand = new RelayCommand(() => App.Current?.ShowMainWindow()),
            ContextFlyout = menu,
        };
        menu.Opening += (_, _) => BuildMenu();
        BuildMenu();
        icon.ForceCreate(enablesEfficiencyMode: false);
        model.Changed += _ => icon.ToolTipText = "GitSync · " + model.OverallStatusText;
    }

    void BuildMenu()
    {
        menu.Items.Clear();
        menu.Items.Add(Ui.MenuItem(L.T("打开 GitSync", "Open GitSync"), () => App.Current?.ShowMainWindow(), Glyph.Window));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(Ui.MenuItem(L.T("全部同步", "Sync All"), () => model.SyncAll(SyncTrigger.ManualAll), Glyph.Sync,
                                   model.Repositories.Count > 0 && model.Git != null));
        var running = model.AutoSyncCount > 0;
        var toggle = new ToggleMenuFlyoutItem { Text = L.T("自动同步", "Auto Sync"), IsChecked = running };
        toggle.Click += (_, _) => model.SetAutoSyncForAll(!running);
        menu.Items.Add(toggle);
        if (model.NextSyncDate is { } next && running)
            menu.Items.Add(new MenuFlyoutItem
            {
                Text = L.T($"每 {model.Settings.IntervalMinutes} 分钟 · 下次 {next:HH:mm}", $"Every {model.Settings.IntervalMinutes} min · next {next:HH:mm}"),
                IsEnabled = false,
            });

        if (model.Repositories.Count > 0)
        {
            menu.Items.Add(new MenuFlyoutSeparator());
            foreach (var repo in model.Repositories.Take(12))
            {
                var status = model.DisplayStatus(repo);
                var item = Ui.MenuItem($"{repo.DisplayName} · {status.DisplayName()}", () => model.Sync(repo.Id, SyncTrigger.ManualSingle),
                                       status.IsProblem() ? Glyph.Warning : Glyph.Sync);
                ToolTipService.SetToolTip(item, L.T("立即同步", "Sync now"));
                menu.Items.Add(item);
            }
        }
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(Ui.MenuItem(L.T("设置", "Settings"), () => SettingsWindow.Show(model), Glyph.Settings));
        menu.Items.Add(Ui.MenuItem(L.T("退出", "Quit"), () => _ = App.Current?.QuitAsync(), Glyph.Power));
    }

    public void Dispose() => icon.Dispose();
}
