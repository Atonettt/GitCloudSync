using System.Runtime.InteropServices;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;

namespace GitSync.App;

public static class Program
{
    /// <summary>Started at login: stay in the notification area without opening the window.</summary>
    public static bool StartedInBackground { get; private set; }

    [STAThread]
    static int Main(string[] args)
    {
        WinRT.ComWrappersSupport.InitializeComWrappers();
        StartedInBackground = args.Contains("--background");

        // One GitSync per user: a second launch brings the first one's window to the front.
        var instance = AppInstance.FindOrRegisterForKey("GitSync.Main");
        if (!instance.IsCurrent)
        {
            instance.RedirectActivationToAsync(AppInstance.GetCurrent().GetActivatedEventArgs()).AsTask().Wait();
            return 0;
        }
        instance.Activated += (_, _) => App.Current?.ShowMainWindow();

        Application.Start(_parameters =>
        {
            var context = new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread());
            SynchronizationContext.SetSynchronizationContext(context);
            _ = new App();
        });
        return 0;
    }
}

static partial class Native
{
    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool SetForegroundWindow(nint hwnd);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool ShowWindow(nint hwnd, int command);

    public const int SW_RESTORE = 9;
}
