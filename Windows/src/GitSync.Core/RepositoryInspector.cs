using System.Text;

namespace GitSync.Core;

/// <summary>Snapshot of a repository, gathered with local read-only commands (no network).</summary>
public sealed record RepositoryInfo(
    string TopLevelPath,
    string GitDirectory,
    string? Branch,
    bool IsUnborn,
    string? RemoteUrl,
    string? Upstream,
    int Ahead,
    int Behind,
    int ChangedFiles,
    InProgressOperation? InProgressOperation,
    IReadOnlyList<string> UnmergedFiles,
    bool IndexLocked)
{
    public bool IsDetached => Branch == null;
    public Uri? WebUrl => RemoteUrl == null ? null : WebUrlFromRemote(RemoteUrl);
    public bool IsGitHubRemote => RemoteUrl?.Contains("github.com", StringComparison.OrdinalIgnoreCase) == true;

    /// <summary>https://github.com/owner/repo for both HTTPS and SSH remotes.</summary>
    public static Uri? WebUrlFromRemote(string remote)
    {
        var value = remote.Trim();
        if (value.StartsWith("git@"))
        {
            value = "https://" + value[4..];
            var colon = value.IndexOf(':', 8);
            if (colon > 0) value = value[..colon] + "/" + value[(colon + 1)..];
        }
        else if (value.StartsWith("ssh://git@"))
        {
            value = "https://" + value["ssh://git@".Length..];
        }
        if (value.EndsWith(".git")) value = value[..^4];
        if (!Uri.TryCreate(value, UriKind.Absolute, out var uri) || !uri.Scheme.StartsWith("http")) return null;
        return new UriBuilder(uri) { UserName = "", Password = "" }.Uri;
    }
}

/// <summary>One entry of <c>git status --porcelain=v1 -z</c>.</summary>
public sealed record StatusEntry(char Index, char Worktree, string Path, string? OriginalPath)
{
    public bool IsUntracked => Index == '?';
    public bool IsDeletion => Index == 'D' || Worktree == 'D';
    public bool IsUnmerged => Index == 'U' || Worktree == 'U' || (Index == 'A' && Worktree == 'A') || (Index == 'D' && Worktree == 'D');

    public static List<StatusEntry> Parse(byte[] data)
    {
        var fields = Fields(data);
        var entries = new List<StatusEntry>();
        for (var i = 0; i < fields.Count; i++)
        {
            var field = fields[i];
            if (field.Length < 4) continue;
            char x = field[0], y = field[1];
            var path = field[3..];
            string? original = null;
            if ((x is 'R' or 'C' || y is 'R' or 'C') && i + 1 < fields.Count) original = fields[++i];
            entries.Add(new StatusEntry(x, y, path, original));
        }
        return entries;
    }

    /// <summary>NUL-separated output split into strings.</summary>
    public static List<string> Fields(byte[] data) =>
        Encoding.UTF8.GetString(data).Split('\0', StringSplitOptions.RemoveEmptyEntries).ToList();
}

public sealed class RepositoryInspector(GitClient client)
{
    public GitClient Client { get; } = client;

    public async Task<RepositoryInfo> InspectAsync()
    {
        var path = Client.RepositoryPath;
        if (!Directory.Exists(path))
            throw new SyncFailure(FailureKind.FolderMissing, SyncStage.Inspect,
                message: L.T($"本地文件夹不存在或已被移动：{path}", $"The folder is missing or was moved: {path}"));

        var top = await Git(["rev-parse", "--show-toplevel"]);
        if (!top.Succeeded)
        {
            var failure = SyncFailure.From(top, SyncStage.Inspect, "git rev-parse --show-toplevel");
            if (failure.Kind is FailureKind.Unknown or FailureKind.NotARepository)
                failure = new SyncFailure(FailureKind.NotARepository, SyncStage.Inspect, failure.Command, failure.ExitCode, failure.Stderr,
                                          L.T($"所选文件夹不是 Git 仓库：{path}", $"The folder isn't a Git repository: {path}"));
            throw failure;
        }
        var topLevel = NormalizePath(top.Stdout.Trim());
        var gitDir = NormalizePath((await Git(["rev-parse", "--absolute-git-dir"])).Stdout.Trim());

        var branchResult = await Git(["symbolic-ref", "--quiet", "--short", "HEAD"]);
        var branch = branchResult.Succeeded ? branchResult.Stdout.Trim() : null;
        var isUnborn = !(await Git(["rev-parse", "--verify", "--quiet", "HEAD"])).Succeeded;
        var remote = await Git(["remote", "get-url", "origin"]);
        var remoteUrl = remote.Succeeded ? remote.Stdout.Trim() : null;
        var upstream = await ResolveUpstreamAsync(branch);

        var (ahead, behind) = (0, 0);
        if (upstream != null && !isUnborn) (ahead, behind) = await AheadBehindAsync(upstream);

        var status = await Git(["status", "--porcelain=v1", "-z", "--untracked-files=all"], TimeSpan.FromSeconds(120));
        var entries = status.Succeeded ? StatusEntry.Parse(status.StdoutData) : [];

        return new RepositoryInfo(topLevel, gitDir, branch, isUnborn, remoteUrl, upstream, ahead, behind, entries.Count,
                                  InProgress(gitDir), await UnmergedPathsAsync(), File.Exists(Path.Combine(gitDir, "index.lock")));
    }

    /// <summary>git prints "C:/Users/…"; turn it into the system's form.</summary>
    public static string NormalizePath(string path) =>
        string.IsNullOrEmpty(path) ? path : Path.GetFullPath(path.Replace('/', Path.DirectorySeparatorChar));

    /// <summary>"origin/main" style name of the branch to integrate with, or null if it doesn't exist on GitHub yet.</summary>
    public async Task<string?> ResolveUpstreamAsync(string? branch)
    {
        var configured = await Git(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"]);
        if (configured.Succeeded)
        {
            var name = configured.Stdout.Trim();
            if ((await Git(["rev-parse", "--verify", "--quiet", $"refs/remotes/{name}"])).Succeeded) return name;
        }
        if (branch == null) return null;
        return (await Git(["rev-parse", "--verify", "--quiet", $"refs/remotes/origin/{branch}"])).Succeeded ? $"origin/{branch}" : null;
    }

    /// <summary>The branch GitHub shows by default: the fetched remote HEAD, else main or master, else the only branch.</summary>
    public async Task<string?> RemoteDefaultBranchAsync()
    {
        var head = await Git(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"]);
        if (head.Succeeded)
        {
            var name = head.Stdout.Trim();
            if ((await Git(["rev-parse", "--verify", "--quiet", $"refs/remotes/{name}"])).Succeeded) return name;
        }
        var refs = await Git(["for-each-ref", "--format=%(refname)", "refs/remotes/origin/"]);
        if (!refs.Succeeded) return null;
        var names = refs.Stdout.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Select(r => r["refs/remotes/".Length..]).Where(n => n != "origin/HEAD").ToList();
        foreach (var preferred in new[] { "origin/main", "origin/master" })
            if (names.Contains(preferred)) return preferred;
        return names.Count == 1 ? names[0] : null;
    }

    public async Task<(int Ahead, int Behind)> AheadBehindAsync(string upstream)
    {
        var result = await Git(["rev-list", "--left-right", "--count", $"HEAD...{upstream}"]);
        if (!result.Succeeded) return (0, 0);
        var numbers = result.Stdout.Split([' ', '\t', '\n'], StringSplitOptions.RemoveEmptyEntries)
            .Select(s => int.TryParse(s, out var n) ? n : -1).Where(n => n >= 0).ToList();
        return numbers.Count == 2 ? (numbers[0], numbers[1]) : (0, 0);
    }

    public async Task<List<string>> UnmergedPathsAsync()
    {
        var result = await Git(["diff", "--name-only", "--diff-filter=U", "-z"]);
        return result.Succeeded ? StatusEntry.Fields(result.StdoutData) : [];
    }

    public static InProgressOperation? InProgress(string gitDirectory)
    {
        bool Exists(string name) => File.Exists(Path.Combine(gitDirectory, name)) || Directory.Exists(Path.Combine(gitDirectory, name));
        if (Exists("rebase-merge") || Exists("rebase-apply")) return InProgressOperation.Rebase;
        if (Exists("MERGE_HEAD")) return InProgressOperation.Merge;
        if (Exists("CHERRY_PICK_HEAD")) return InProgressOperation.CherryPick;
        if (Exists("REVERT_HEAD")) return InProgressOperation.Revert;
        return null;
    }

    async Task<ProcessResult> Git(IReadOnlyList<string> args, TimeSpan? timeout = null)
    {
        try
        {
            return await Client.RunAsync(args, timeout ?? TimeSpan.FromSeconds(30));
        }
        catch (ProcessLaunchException error)
        {
            throw new SyncFailure(FailureKind.GitUnavailable, SyncStage.Inspect, "git " + string.Join(" ", args), stderr: error.Message);
        }
    }
}
