using GitSync.App.Services;
using GitSync.App.Views;
using GitSync.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace GitSync.App;

/// <summary>
/// The application: one model, a notification-area icon that keeps syncing when the window is
/// closed, and the main window. The interface is built in C#, so there is no App.xaml.
/// </summary>
public sealed partial class App : Application
{
    public static new App? Current { get; private set; }
    public AppModel Model { get; private set; } = null!;
    MainWindow? mainWindow;
    TrayIcon? tray;

    public App()
    {
        Current = this;
#if WINDOWS_XAML
        InitializeComponent();   // App.xaml: WinUI's control styles and theme resources
#endif
        UnhandledException += (_, e) =>
        {
            Program.WriteCrash("XAML", e.Exception);
            Model?.Log(null, L.T("程序错误", "App error"), LogLevel.Error, e.Message, detail: e.Exception?.ToString());
            e.Handled = true;
        };
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        try
        {
            Model = new AppModel();
            try { tray = new TrayIcon(Model); }
            catch (Exception error) { Program.WriteCrash("Tray icon", error); }
            if (!Program.StartedInBackground) ShowMainWindow();
            _ = StartModel();
        }
        catch (Exception error)
        {
            Program.WriteCrash("Launch", error);
            throw;
        }
    }

    async Task StartModel()
    {
        try { await Model.StartAsync(); }
        catch (Exception error) { Program.WriteCrash("Start", error); }
    }

    public void ShowMainWindow()
    {
        DispatcherQueueExtensions.RunOnUi(() =>
        {
            if (mainWindow == null)
            {
                mainWindow = new MainWindow(Model);
                mainWindow.Closed += (_, _) => mainWindow = null;
            }
            mainWindow.Activate();
            mainWindow.BringToFront();
        });
    }

    /// <summary>Quits for real (the window's close button only hides GitSync in the notification area).</summary>
    public async Task QuitAsync()
    {
        await Model.ShutdownAsync();
        tray?.Dispose();
        Exit();
    }
}
