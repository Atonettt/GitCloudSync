using System.Runtime.InteropServices;

namespace GitSync.Core;

/// <summary>Chinese → pinyin through the ICU library the system ships (icu.dll on Windows 10+, libicucore on macOS).</summary>
public static partial class Transliteration
{
    const string WindowsIcu = "icu.dll";
    const string MacIcu = "/usr/lib/libicucore.dylib";

    /// <summary>"研究资料" → "yan jiu zi liao"; the input unchanged when ICU isn't available.</summary>
    public static string ToLatin(string text)
    {
        try
        {
            return OperatingSystem.IsWindows() ? Transform(text, WindowsApi.Open, WindowsApi.Trans, WindowsApi.Close)
                 : OperatingSystem.IsMacOS() ? Transform(text, MacApi.Open, MacApi.Trans, MacApi.Close)
                 : text;
        }
        catch (Exception error) when (error is DllNotFoundException or EntryPointNotFoundException or BadImageFormatException)
        {
            return text;
        }
    }

    delegate nint OpenFn(string id, int idLength, int direction, nint rules, int rulesLength, byte[] parseError, ref int status);
    delegate void TransFn(nint transliterator, char[] text, ref int textLength, int capacity, int start, ref int limit, ref int status);
    delegate void CloseFn(nint transliterator);

    static string Transform(string text, OpenFn open, TransFn trans, CloseFn close)
    {
        const string id = "Han-Latin; Latin-ASCII";
        var status = 0;
        var handle = open(id, id.Length, 0, 0, 0, new byte[72], ref status);
        if (handle == 0 || status > 0) return text;
        try
        {
            var capacity = text.Length * 8 + 16;
            var buffer = new char[capacity];
            text.CopyTo(0, buffer, 0, text.Length);
            var length = text.Length;
            var limit = text.Length;
            trans(handle, buffer, ref length, capacity, 0, ref limit, ref status);
            return status > 0 ? text : new string(buffer, 0, length);
        }
        finally
        {
            close(handle);
        }
    }

    static class WindowsApi
    {
        [DllImport(WindowsIcu, EntryPoint = "utrans_openU", CharSet = CharSet.Unicode)]
        static extern nint OpenNative(string id, int idLength, int direction, nint rules, int rulesLength, byte[] parseError, ref int status);
        [DllImport(WindowsIcu, EntryPoint = "utrans_transUChars", CharSet = CharSet.Unicode)]
        static extern void TransNative(nint transliterator, [In, Out] char[] text, ref int textLength, int capacity, int start, ref int limit, ref int status);
        [DllImport(WindowsIcu, EntryPoint = "utrans_close")]
        static extern void CloseNative(nint transliterator);
        public static nint Open(string id, int idLength, int direction, nint rules, int rulesLength, byte[] parseError, ref int status) =>
            OpenNative(id, idLength, direction, rules, rulesLength, parseError, ref status);
        public static void Trans(nint t, char[] text, ref int textLength, int capacity, int start, ref int limit, ref int status) =>
            TransNative(t, text, ref textLength, capacity, start, ref limit, ref status);
        public static void Close(nint t) => CloseNative(t);
    }

    static class MacApi
    {
        [DllImport(MacIcu, EntryPoint = "utrans_openU", CharSet = CharSet.Unicode)]
        static extern nint OpenNative(string id, int idLength, int direction, nint rules, int rulesLength, byte[] parseError, ref int status);
        [DllImport(MacIcu, EntryPoint = "utrans_transUChars", CharSet = CharSet.Unicode)]
        static extern void TransNative(nint transliterator, [In, Out] char[] text, ref int textLength, int capacity, int start, ref int limit, ref int status);
        [DllImport(MacIcu, EntryPoint = "utrans_close")]
        static extern void CloseNative(nint transliterator);
        public static nint Open(string id, int idLength, int direction, nint rules, int rulesLength, byte[] parseError, ref int status) =>
            OpenNative(id, idLength, direction, rules, rulesLength, parseError, ref status);
        public static void Trans(nint t, char[] text, ref int textLength, int capacity, int start, ref int limit, ref int status) =>
            TransNative(t, text, ref textLength, capacity, start, ref limit, ref status);
        public static void Close(nint t) => CloseNative(t);
    }
}

/// <summary>GitHub's rules for repository names.</summary>
public static class RepositoryNaming
{
    public const int MaxLength = 100;

    /// <summary>
    /// A valid name derived from a folder name: Chinese is written in pinyin, accents are dropped,
    /// other characters become "-" ("研究资料 2026" → "yan-jiu-zi-liao-2026"). "" when nothing is left.
    /// </summary>
    public static string SuggestedName(string folderName)
    {
        var hasChinese = folderName.Any(c => c is >= '㐀' and <= '鿿' or >= '豈' and <= '﫿');
        var latin = hasChinese ? Transliteration.ToLatin(folderName) : StripDiacritics(folderName);
        var result = new System.Text.StringBuilder();
        foreach (var c in latin)
        {
            if (IsAllowed(c)) result.Append(c);
            else if (result.Length > 0 && result[^1] != '-') result.Append('-');
        }
        var name = result.ToString().Trim('-', '.');
        if (name.EndsWith(".git", StringComparison.OrdinalIgnoreCase)) name = name[..^4].TrimEnd('-', '.');
        return name.Length > MaxLength ? name[..MaxLength] : name;
    }

    static string StripDiacritics(string text)
    {
        var decomposed = text.Normalize(System.Text.NormalizationForm.FormD);
        return new string(decomposed.Where(c => System.Globalization.CharUnicodeInfo.GetUnicodeCategory(c)
                                                != System.Globalization.UnicodeCategory.NonSpacingMark).ToArray())
            .Normalize(System.Text.NormalizationForm.FormC);
    }

    /// <summary>null when the name can be used as is; otherwise a message for the user.</summary>
    public static string? Problem(string name)
    {
        if (name.Length == 0) return L.T("请输入仓库名", "Enter a repository name");
        if (name.Length > MaxLength) return L.T($"仓库名不能超过 {MaxLength} 个字符", $"Names can't be longer than {MaxLength} characters");
        if (name is "." or "..") return L.T("仓库名不能是「.」或「..」", "The name can't be “.” or “..”");
        if (name.EndsWith(".git", StringComparison.OrdinalIgnoreCase)) return L.T("仓库名不能以 .git 结尾", "The name can't end with .git");
        if (!name.All(IsAllowed))
            return L.T("GitHub 仓库名只能包含英文字母、数字、-、_ 和 .（本地文件夹名不受影响，可以保留中文）",
                       "GitHub names can only contain letters, digits, -, _ and . (the folder keeps its own name)");
        return null;
    }

    static bool IsAllowed(char c) => c is >= 'a' and <= 'z' or >= 'A' and <= 'Z' or >= '0' and <= '9' or '-' or '_' or '.';
}

public enum FolderKind { PlainFolder, RepositoryWithoutRemote, LinkedRepository, InsideRepository }

/// <summary>What a folder holds before it is turned into a synced repository.</summary>
public sealed record FolderPreview(
    FolderKind Kind,
    int FileCount,
    long TotalBytes,
    IReadOnlyList<(string Path, long Bytes)> Oversized,
    bool Truncated,
    int Commits = 0,
    string? Remote = null,
    string? EnclosingRoot = null,
    bool IsInOneDrive = false);

/// <summary>Turns a plain folder into a repository GitSync can sync. Only touches the local folder.</summary>
public sealed class RepositoryCreator(GitEnvironment git)
{
    public GitEnvironment Git { get; } = git;

    /// <summary>Folders that must never become a repository.</summary>
    public static string? RefusalReason(string folder)
    {
        var path = Canonical(folder);
        var home = Canonical(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile));
        var forbidden = new List<string> { home };
        foreach (var special in new[] { Environment.SpecialFolder.Desktop, Environment.SpecialFolder.MyDocuments,
                                        Environment.SpecialFolder.Windows, Environment.SpecialFolder.ProgramFiles,
                                        Environment.SpecialFolder.ProgramFilesX86, Environment.SpecialFolder.ApplicationData,
                                        Environment.SpecialFolder.LocalApplicationData })
        {
            var value = Environment.GetFolderPath(special);
            if (!string.IsNullOrEmpty(value)) forbidden.Add(Canonical(value));
        }
        forbidden.Add(Canonical(Path.Combine(home, "Downloads")));
        var root = Path.GetPathRoot(path);
        if (forbidden.Contains(path, StringComparer.OrdinalIgnoreCase) || string.Equals(root?.TrimEnd('\\', '/'), path.TrimEnd('\\', '/'), StringComparison.OrdinalIgnoreCase) || path == "/")
            return L.T($"不能把「{Path.GetFileName(folder.TrimEnd('\\', '/'))}」整个文件夹作为仓库，请在里面新建一个文件夹再拖进来。",
                       $"“{Path.GetFileName(folder.TrimEnd('\\', '/'))}” can't be a repository as a whole; create a folder inside it and drag that in.");
        var appData = Path.Combine(home, "AppData");
        if (path.StartsWith(appData + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            return L.T("不能使用 AppData 中的文件夹。", "Folders inside AppData can't be used.");
        return null;
    }

    public async Task<FolderPreview> PreviewAsync(string folder, long largeFileLimit, IReadOnlyList<string> ignorePatterns, int maxEntries = 100_000)
    {
        var client = new GitClient(folder, Git);
        var top = await client.RunAsync(["rev-parse", "--show-toplevel"], TimeSpan.FromSeconds(15));
        var kind = FolderKind.PlainFolder;
        int commits = 0;
        string? remote = null, enclosing = null;
        if (top.Succeeded)
        {
            var root = RepositoryInspector.NormalizePath(top.Stdout.Trim());
            var origin = await client.RunAsync(["remote", "get-url", "origin"], TimeSpan.FromSeconds(15));
            if (!string.Equals(Canonical(root), Canonical(folder), StringComparison.OrdinalIgnoreCase))
            {
                kind = FolderKind.InsideRepository;
                enclosing = root;
            }
            else if (origin.Succeeded)
            {
                kind = FolderKind.LinkedRepository;
                remote = origin.Stdout.Trim();
            }
            else
            {
                kind = FolderKind.RepositoryWithoutRemote;
                var count = await client.RunAsync(["rev-list", "--count", "HEAD"], TimeSpan.FromSeconds(15));
                _ = int.TryParse(count.Stdout.Trim(), out commits);
            }
        }
        var scan = Scan(folder, largeFileLimit, ignorePatterns, maxEntries);
        var oneDrive = Environment.GetEnvironmentVariable("OneDrive") is { Length: > 0 } od &&
                       Canonical(folder).StartsWith(Canonical(od), StringComparison.OrdinalIgnoreCase);
        return new FolderPreview(kind, scan.Count, scan.Bytes, scan.Oversized, scan.Truncated, commits, remote, enclosing, oneDrive);
    }

    /// <summary>
    /// Prepares the folder for its first sync: git init when needed, GitSync's ignore rules, a private
    /// commit identity, and origin pointing at the remote. Returns true when this created the repository.
    /// </summary>
    public async Task<bool> PrepareAsync(string folder, string remoteUrl, GitIdentity? identity, IReadOnlyList<string> ignorePatterns)
    {
        var client = new GitClient(folder, Git);
        var created = false;
        var top = await client.RunAsync(["rev-parse", "--show-toplevel"], TimeSpan.FromSeconds(15));
        if (!top.Succeeded)
        {
            await Checked(client, ["init", "--quiet", "-b", "main"]);
            created = true;
        }
        else
        {
            var root = RepositoryInspector.NormalizePath(top.Stdout.Trim());
            if (!string.Equals(Canonical(root), Canonical(folder), StringComparison.OrdinalIgnoreCase))
                throw new SyncFailure(FailureKind.Unknown, SyncStage.Preflight,
                                      message: L.T($"该文件夹位于另一个 Git 仓库内：{root}", $"The folder is inside another Git repository: {root}"));
        }
        var gitDir = RepositoryInspector.NormalizePath((await Checked(client, ["rev-parse", "--absolute-git-dir"])).Stdout.Trim());
        IgnoreRules.Apply(ignorePatterns, gitDir);
        // Plain line endings: files come back byte for byte, as on the other computers.
        await Checked(client, ["config", "--local", "core.autocrlf", "false"]);

        // Commits go to GitHub, so use the account's private noreply address, not the global git email.
        if (identity != null)
        {
            var localEmail = await client.RunAsync(["config", "--local", "--get", "user.email"], TimeSpan.FromSeconds(15));
            if (!localEmail.Succeeded || localEmail.Stdout.Trim().Length == 0)
            {
                await Checked(client, ["config", "--local", "user.name", identity.Name]);
                await Checked(client, ["config", "--local", "user.email", identity.Email]);
            }
        }

        var existing = await client.RunAsync(["remote", "get-url", "origin"], TimeSpan.FromSeconds(15));
        if (existing.Succeeded)
        {
            var current = existing.Stdout.Trim();
            if (current != remoteUrl)
                throw new SyncFailure(FailureKind.Unknown, SyncStage.Preflight,
                                      message: L.T($"该仓库已经关联了远程地址 {current}", $"The repository is already linked to {current}"));
        }
        else
        {
            await Checked(client, ["remote", "add", "origin", remoteUrl]);
        }
        return created;
    }

    /// <summary>
    /// Downloads a GitHub repository into a folder that doesn't exist yet or is empty, so nothing local
    /// is ever replaced. The clone goes to a hidden folder first and is moved into place when complete.
    /// </summary>
    public async Task DownloadAsync(string remoteUrl, string destination, GitCredential? credential, GitIdentity? identity,
                                    IReadOnlyList<string> ignorePatterns, TimeSpan? timeout = null)
    {
        if (Directory.Exists(destination))
        {
            var contents = Directory.EnumerateFileSystemEntries(destination)
                .Where(e => Path.GetFileName(e) is not (".DS_Store" or "desktop.ini" or "Thumbs.db")).ToList();
            if (contents.Count > 0)
                throw new SyncFailure(FailureKind.Unknown, SyncStage.Fetch,
                                      message: L.T($"「{destination}」已存在且不是空的，GitSync 不会覆盖它。",
                                                   $"“{destination}” already exists and isn't empty; GitSync won't overwrite it."));
        }
        else if (File.Exists(destination))
        {
            throw new SyncFailure(FailureKind.Unknown, SyncStage.Fetch,
                                  message: L.T($"「{destination}」已存在且不是空的，GitSync 不会覆盖它。",
                                               $"“{destination}” already exists and isn't empty; GitSync won't overwrite it."));
        }
        var parent = Path.GetDirectoryName(Path.GetFullPath(destination))!;
        Directory.CreateDirectory(parent);
        var staging = Path.Combine(parent, $".{Path.GetFileName(destination)}.gitsync-download-{Guid.NewGuid().ToString("N")[..8]}");
        try
        {
            var client = new GitClient(parent, Git, credential);
            var result = await client.RunAsync(["-c", "core.autocrlf=false", "clone", "--quiet", remoteUrl, staging], timeout ?? TimeSpan.FromHours(1));
            if (!result.Succeeded) throw SyncFailure.From(result, SyncStage.Fetch, $"git clone {remoteUrl}");
            if (Directory.Exists(destination)) Directory.Delete(destination, recursive: true);
            Directory.Move(staging, destination);
        }
        finally
        {
            if (Directory.Exists(staging)) TryDelete(staging);
        }
        await PrepareAsync(destination, remoteUrl, identity, ignorePatterns);
    }

    /// <summary>True when the remote has no branches yet, so linking to it can't clash with local history.</summary>
    public async Task<bool> RemoteIsEmptyAsync(string remoteUrl, GitCredential? credential, string folder)
    {
        var client = new GitClient(folder, Git, credential);
        var result = await client.RunAsync(["ls-remote", "--heads", remoteUrl], TimeSpan.FromSeconds(60));
        if (!result.Succeeded) throw SyncFailure.From(result, SyncStage.Fetch, $"git ls-remote --heads {remoteUrl}");
        return result.Stdout.Trim().Length == 0;
    }

    /// <summary>
    /// The full path with "..", trailing separators and links (symlinks, junctions) in any component
    /// resolved, for comparing with what git prints.
    /// </summary>
    public static string Canonical(string path)
    {
        try
        {
            var full = Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            var root = Path.GetPathRoot(full) ?? "";
            var resolved = root;
            foreach (var part in full[root.Length..].Split(Path.DirectorySeparatorChar, StringSplitOptions.RemoveEmptyEntries))
            {
                resolved = Path.Combine(resolved, part);
                var info = new DirectoryInfo(resolved);
                if (info.Exists && info.LinkTarget != null && info.ResolveLinkTarget(returnFinalTarget: true) is { } target)
                    resolved = target.FullName;
            }
            return resolved.Length > root.Length ? resolved.TrimEnd(Path.DirectorySeparatorChar) : resolved;
        }
        catch
        {
            return path;
        }
    }

    public static (int Count, long Bytes, List<(string Path, long Bytes)> Oversized, bool Truncated) Scan(
        string folder, long largeFileLimit, IReadOnlyList<string> ignorePatterns, int maxEntries)
    {
        int count = 0, visited = 0;
        long bytes = 0;
        var oversized = new List<(string, long)>();
        var pending = new Stack<string>();
        pending.Push(folder);
        while (pending.Count > 0)
        {
            var directory = pending.Pop();
            IEnumerable<string> entries;
            try { entries = Directory.EnumerateFileSystemEntries(directory); } catch { continue; }
            foreach (var entry in entries)
            {
                if (++visited > maxEntries) return (count, bytes, oversized, true);
                var name = Path.GetFileName(entry);
                if (name == ".git" || IgnoreRules.IsIgnored(name, ignorePatterns)) continue;
                if (Directory.Exists(entry))
                {
                    if (!new DirectoryInfo(entry).Attributes.HasFlag(FileAttributes.ReparsePoint)) pending.Push(entry);
                    continue;
                }
                long size;
                try { size = new FileInfo(entry).Length; } catch { continue; }
                count++;
                bytes += size;
                if (size > largeFileLimit)
                    oversized.Add((Path.GetRelativePath(folder, entry).Replace('\\', '/'), size));
            }
        }
        return (count, bytes, oversized, false);
    }

    static void TryDelete(string directory)
    {
        try
        {
            foreach (var file in Directory.EnumerateFiles(directory, "*", SearchOption.AllDirectories)) File.SetAttributes(file, FileAttributes.Normal);
            Directory.Delete(directory, recursive: true);
        }
        catch { /* best effort */ }
    }

    static async Task<ProcessResult> Checked(GitClient client, IReadOnlyList<string> args)
    {
        var result = await client.RunAsync(args, TimeSpan.FromSeconds(60));
        if (!result.Succeeded) throw SyncFailure.From(result, SyncStage.Preflight, "git " + string.Join(" ", args.Select(ProcessResult.Quote)));
        return result;
    }
}
