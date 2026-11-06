using System.Globalization;

namespace GitSync.Core;

/// <summary>What would be lost by deleting one side of a synced repository.</summary>
public sealed record DeletionCheck(int UncommittedFiles = 0, int UnpushedCommits = 0, int? RemoteOnlyCommits = null)
{
    /// <summary>Something exists only on this computer.</summary>
    public bool HasLocalOnlyWork => UncommittedFiles > 0 || UnpushedCommits > 0;
}

/// <summary>Local Git work around deleting a repository's GitHub copy or its local folder.</summary>
public sealed class RepositoryRemoval(GitClient client)
{
    public GitClient Client { get; } = client;

    /// <summary>Counts local work GitHub doesn't have; with fetch, also commits that exist only on GitHub.</summary>
    public async Task<DeletionCheck> CheckAsync(bool fetch)
    {
        var status = await Git(["status", "--porcelain=v1", "-z", "--untracked-files=all"]);
        var uncommitted = StatusEntry.Parse(status.StdoutData).Count;
        if (fetch) await Git(["fetch", "--prune", "origin"], TimeSpan.FromSeconds(300));
        var hasHead = (await Client.RunAsync(["rev-parse", "--verify", "--quiet", "HEAD"], TimeSpan.FromSeconds(15))).Succeeded;
        int unpushed = 0;
        int? remoteOnly = null;
        if (hasHead)
        {
            unpushed = await Count(["rev-list", "--count", "HEAD", "--not", "--remotes=origin"]);
            if (fetch) remoteOnly = await Count(["rev-list", "--count", "--remotes=origin", "--not", "HEAD"]);
        }
        else if (fetch)
        {
            remoteOnly = await Count(["rev-list", "--count", "--remotes=origin"]);
        }
        return new DeletionCheck(uncommitted, unpushed, remoteOnly);
    }

    /// <summary>
    /// After the GitHub repository was deleted: renames origin (keeping every downloaded commit) and
    /// clears the upstream, so the folder is local-only and can later be published again.
    /// </summary>
    public async Task<string> DetachDeletedRemoteAsync()
    {
        var name = "github-deleted-" + DateTime.Now.ToString("yyyyMMdd-HHmmss", CultureInfo.InvariantCulture);
        await Git(["remote", "rename", "origin", name]);
        await Client.RunAsync(["branch", "--unset-upstream"], TimeSpan.FromSeconds(15));
        return name;
    }

    /// <summary>owner/name for a github.com remote, null for anything else.</summary>
    public static (string Owner, string Name)? GitHubFullName(string remote)
    {
        if (RepositoryInfo.WebUrlFromRemote(remote) is not { } url || !url.Host.Equals("github.com", StringComparison.OrdinalIgnoreCase)) return null;
        var parts = url.AbsolutePath.Split('/', StringSplitOptions.RemoveEmptyEntries);
        return parts.Length == 2 ? (Uri.UnescapeDataString(parts[0]), Uri.UnescapeDataString(parts[1])) : null;
    }

    async Task<int> Count(IReadOnlyList<string> args) => int.TryParse((await Git(args)).Stdout.Trim(), out var n) ? n : 0;

    async Task<ProcessResult> Git(IReadOnlyList<string> args, TimeSpan? timeout = null)
    {
        var result = await Client.RunAsync(args, timeout ?? TimeSpan.FromSeconds(120));
        if (!result.Succeeded)
            throw SyncFailure.From(result, args[0] == "fetch" ? SyncStage.Fetch : SyncStage.Inspect, "git " + string.Join(" ", args));
        return result;
    }
}

public enum UsageLevel { Normal, Large, VeryLarge }

/// <summary>Disk space used by a repository: the files themselves and the history kept in .git.</summary>
public sealed record RepositoryUsage(long FileBytes, long HistoryBytes, DateTimeOffset MeasuredAt)
{
    /// <summary>GitHub recommends keeping repositories below 1 GB, and warns above 5 GB.</summary>
    public const long LargeThreshold = 1L << 30, VeryLargeThreshold = 5L << 30;

    public UsageLevel Level => HistoryBytes >= VeryLargeThreshold ? UsageLevel.VeryLarge
                             : HistoryBytes >= LargeThreshold ? UsageLevel.Large : UsageLevel.Normal;
}

/// <summary>How much of the history one path accounts for, across all of its versions.</summary>
public sealed record HistoryFileUsage(string Path, int Versions, long StoredBytes, long LargestVersionBytes);

/// <summary>Read-only size measurements.</summary>
public sealed class RepositoryUsageScanner(GitClient client)
{
    public GitClient Client { get; } = client;

    /// <summary>Pass reusingFileBytes when the files haven't changed: walking a big folder is the expensive part.</summary>
    public async Task<RepositoryUsage> MeasureAsync(long? reusingFileBytes = null)
    {
        var history = await HistorySizeAsync();
        if (reusingFileBytes is { } known) return new RepositoryUsage(known, history, DateTimeOffset.Now);
        var gitDir = RepositoryInspector.NormalizePath((await Git(["rev-parse", "--absolute-git-dir"])).Stdout.Trim());
        return new RepositoryUsage(await Task.Run(() => FolderSize(Client.RepositoryPath, gitDir)), history, DateTimeOffset.Now);
    }

    public async Task<long> HistorySizeAsync() => ParseCountObjects((await Git(["count-objects", "-v"])).Stdout);

    /// <summary>Adds loose, packed and garbage sizes (KiB) from <c>git count-objects -v</c>.</summary>
    public static long ParseCountObjects(string output)
    {
        long kib = 0;
        foreach (var line in output.Split('\n'))
        {
            var parts = line.Split(':', 2, StringSplitOptions.TrimEntries);
            if (parts.Length == 2 && parts[0] is "size" or "size-pack" or "size-garbage" && long.TryParse(parts[1], out var value)) kib += value;
        }
        return kib * 1024;
    }

    /// <summary>Paths whose versions take the most space in history, largest first (deleted files included).</summary>
    public async Task<List<HistoryFileUsage>> LargestFilesAsync(int limit = 15)
    {
        var objects = await Git(["rev-list", "--objects", "--all"]);
        if (objects.StdoutData.Length == 0) return [];
        var sizes = await Git(["cat-file", "--batch-check=%(objecttype) %(objectsize) %(objectsize:disk) %(rest)"], objects.StdoutData);
        var usage = new Dictionary<string, (int Versions, long Stored, long Largest)>();
        foreach (var line in sizes.Stdout.Split('\n'))
        {
            var fields = line.TrimEnd('\r').Split(' ', 4);
            if (fields.Length != 4 || fields[0] != "blob" || fields[3].Length == 0 ||
                !long.TryParse(fields[1], out var size) || !long.TryParse(fields[2], out var disk)) continue;
            var entry = usage.GetValueOrDefault(fields[3]);
            usage[fields[3]] = (entry.Versions + 1, entry.Stored + disk, Math.Max(entry.Largest, size));
        }
        return usage.Select(p => new HistoryFileUsage(p.Key, p.Value.Versions, p.Value.Stored, p.Value.Largest))
                    .OrderByDescending(u => u.StoredBytes).Take(limit).ToList();
    }

    static long FolderSize(string folder, string excluded)
    {
        long total = 0;
        var pending = new Stack<string>();
        pending.Push(folder);
        while (pending.Count > 0)
        {
            var directory = pending.Pop();
            try
            {
                foreach (var file in Directory.EnumerateFiles(directory))
                {
                    try { total += new FileInfo(file).Length; } catch { }
                }
                foreach (var sub in Directory.EnumerateDirectories(directory))
                {
                    if (!string.Equals(Path.GetFullPath(sub), excluded, StringComparison.OrdinalIgnoreCase)) pending.Push(sub);
                }
            }
            catch { /* unreadable folder */ }
        }
        return total;
    }

    async Task<ProcessResult> Git(IReadOnlyList<string> args, byte[]? stdin = null)
    {
        var result = await Client.RunAsync(args, TimeSpan.FromSeconds(180), stdin);
        if (!result.Succeeded) throw SyncFailure.From(result, SyncStage.Inspect, "git " + string.Join(" ", args));
        return result;
    }
}
