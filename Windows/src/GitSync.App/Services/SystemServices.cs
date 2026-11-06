using System.Diagnostics;
using System.Runtime.InteropServices;
using GitSync.Core;
using Microsoft.Win32;
using Microsoft.Windows.AppNotifications;
using Microsoft.Windows.AppNotifications.Builder;

namespace GitSync.App.Services;

/// <summary>Windows toast notifications.</summary>
public sealed class Notifications
{
    bool registered;

    public void Post(string title, string body)
    {
        try
        {
            if (!registered)
            {
                AppNotificationManager.Default.NotificationInvoked += (_, _) => App.Current?.ShowMainWindow();
                AppNotificationManager.Default.Register();
                registered = true;
            }
            var notification = new AppNotificationBuilder().AddText(title).AddText(body).BuildNotification();
            AppNotificationManager.Default.Show(notification);
        }
        catch
        {
            // Notifications are best effort (for example when Focus is on).
        }
    }

    public void Unregister()
    {
        if (registered) AppNotificationManager.Default.Unregister();
    }
}

/// <summary>Start GitSync when signing in to Windows (per user, no admin rights).</summary>
public static class StartupService
{
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    const string ValueName = "GitSync";

    public static bool IsEnabled
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);
            return key?.GetValue(ValueName) is string;
        }
    }

    public static void SetEnabled(bool enabled)
    {
        using var key = Registry.CurrentUser.CreateSubKey(RunKey);
        if (enabled) key.SetValue(ValueName, $"\"{Environment.ProcessPath}\" --background");
        else key.DeleteValue(ValueName, throwOnMissingValue: false);
    }
}

/// <summary>Opening files, folders and web pages.</summary>
public static class Shell
{
    public static void Open(string pathOrUrl)
    {
        try { Process.Start(new ProcessStartInfo(pathOrUrl) { UseShellExecute = true }); } catch { }
    }

    /// <summary>Opens File Explorer with the item selected.</summary>
    public static void Reveal(string path)
    {
        try
        {
            if (File.Exists(path) || Directory.Exists(path)) Process.Start("explorer.exe", $"/select,\"{path}\"");
            else if (Path.GetDirectoryName(path) is { } parent && Directory.Exists(parent)) Process.Start("explorer.exe", $"\"{parent}\"");
        }
        catch { }
    }

    /// <summary>Moves a file or folder to the Recycle Bin, so it can be restored.</summary>
    public static void MoveToRecycleBin(string path)
    {
        var operation = new SHFILEOPSTRUCT
        {
            wFunc = FO_DELETE,
            pFrom = path + "\0\0",
            fFlags = FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_NOERRORUI | FOF_SILENT,
        };
        var result = SHFileOperation(ref operation);
        if (result != 0 || operation.fAnyOperationsAborted)
            throw new IOException(L.T($"无法移到回收站（错误 {result}）", $"Couldn't move it to the Recycle Bin (error {result})"));
    }

    const uint FO_DELETE = 3;
    const ushort FOF_SILENT = 0x4, FOF_NOCONFIRMATION = 0x10, FOF_ALLOWUNDO = 0x40, FOF_NOERRORUI = 0x400;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct SHFILEOPSTRUCT
    {
        public nint hwnd;
        public uint wFunc;
        public string pFrom;
        public string? pTo;
        public ushort fFlags;
        [MarshalAs(UnmanagedType.Bool)] public bool fAnyOperationsAborted;
        public nint hNameMappings;
        public string? lpszProgressTitle;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    static extern int SHFileOperation(ref SHFILEOPSTRUCT operation);

    public static void CopyText(string text)
    {
        var package = new Windows.ApplicationModel.DataTransfer.DataPackage();
        package.SetText(text);
        Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(package);
    }
}

/// <summary>
/// Follows a repository folder after it was moved or renamed. NTFS gives every folder a file ID
/// that stays the same through moves and renames on the same drive (and into the Recycle Bin).
/// </summary>
public static class FolderLocator
{
    public abstract record Location
    {
        public sealed record Unchanged : Location;
        public sealed record Moved(string Path) : Location;
        public sealed record InRecycleBin(string Path) : Location;
        public sealed record Missing : Location;
    }

    public static string? FileId(string path)
    {
        using var handle = CreateFile(path, 0, 7, 0, 3, FILE_FLAG_BACKUP_SEMANTICS, 0);
        if (handle.IsInvalid) return null;
        if (!GetFileInformationByHandle(handle, out var info)) return null;
        return $"{info.VolumeSerialNumber:X8}-{info.FileIndexHigh:X8}{info.FileIndexLow:X8}";
    }

    public static Location Locate(string path, string? fileId)
    {
        if (Directory.Exists(path))
        {
            if (fileId == null || FileId(path) == fileId) return new Location.Unchanged();
        }
        if (fileId == null) return new Location.Missing();
        foreach (var candidate in Candidates(path))
        {
            if (FileId(candidate) != fileId) continue;
            return IsInRecycleBin(candidate) ? new Location.InRecycleBin(candidate) : new Location.Moved(candidate);
        }
        return new Location.Missing();
    }

    public static bool IsInRecycleBin(string path) => path.Contains("$Recycle.Bin", StringComparison.OrdinalIgnoreCase);

    /// <summary>
    /// Where a moved folder usually ends up: near its old place, in the common user folders and
    /// in the Recycle Bin. Bounded so a check stays fast.
    /// </summary>
    static IEnumerable<string> Candidates(string path)
    {
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var roots = new List<(string Folder, int Depth)>();
        var parent = Path.GetDirectoryName(path);
        for (var level = 0; parent != null && level < 3; level++, parent = Path.GetDirectoryName(parent))
            roots.Add((parent, level == 0 ? 2 : 1));
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        foreach (var name in new[] { "Desktop", "Documents", "Downloads", "OneDrive" })
            roots.Add((Path.Combine(home, name), 3));
        roots.Add((home, 1));
        var drive = Path.GetPathRoot(path);
        if (drive != null) roots.Add((Path.Combine(drive, "$Recycle.Bin"), 2));

        foreach (var (folder, depth) in roots)
        {
            foreach (var directory in Walk(folder, depth))
            {
                if (seen.Add(directory)) yield return directory;
            }
        }
    }

    static IEnumerable<string> Walk(string folder, int depth)
    {
        if (depth < 0 || !Directory.Exists(folder)) yield break;
        string[] children;
        try { children = Directory.GetDirectories(folder); } catch { yield break; }
        foreach (var child in children)
        {
            var name = Path.GetFileName(child);
            if (name.StartsWith('.') || name is "node_modules" or "AppData") continue;
            yield return child;
            foreach (var deeper in Walk(child, depth - 1)) yield return deeper;
        }
    }

    const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;

    [StructLayout(LayoutKind.Sequential)]
    struct BY_HANDLE_FILE_INFORMATION
    {
        public uint FileAttributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime, LastAccessTime, LastWriteTime;
        public uint VolumeSerialNumber, FileSizeHigh, FileSizeLow, NumberOfLinks, FileIndexHigh, FileIndexLow;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "CreateFileW")]
    static extern Microsoft.Win32.SafeHandles.SafeFileHandle CreateFile(string name, uint access, uint share, nint security,
                                                                         uint disposition, uint flags, nint template);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetFileInformationByHandle(Microsoft.Win32.SafeHandles.SafeFileHandle handle, out BY_HANDLE_FILE_INFORMATION info);
}
