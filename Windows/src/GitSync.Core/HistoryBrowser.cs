using System.Globalization;
using System.Text;

namespace GitSync.Core;

public enum CommitKind { AutoSync, Merge, Restore, Other }

/// <summary>One committed version of the repository, as shown in the history UI.</summary>
public sealed record HistoryCommit(string Id, IReadOnlyList<string> Parents, DateTimeOffset Date, string Author, string Subject)
{
    public IReadOnlyList<HistoryChange> Changes { get; init; } = [];
    public string ShortId => Id[..Math.Min(7, Id.Length)];

    // GitSync writes its messages in the app's language (Mac and Windows), so both forms are recognised.
    static readonly string[] Prefixes = ["GitSync：", "GitSync: "];
    static readonly string[] AutoSyncMarkers = [" 自动同步 ", " auto-sync "];
    static readonly string[] MergeMarkers = ["合并来自 GitHub 的更新", "merged updates from GitHub"];
    static readonly string[] RestoreMarkers = [" 恢复", " restored "];

    string? Body => Prefixes.FirstOrDefault(Subject.StartsWith) is { } prefix ? Subject[prefix.Length..] : null;

    public CommitKind Kind
    {
        get
        {
            if (Body is not { } body) return CommitKind.Other;
            if (MergeMarkers.Any(body.StartsWith)) return CommitKind.Merge;
            if (AutoSyncMarkers.Any(body.Contains)) return CommitKind.AutoSync;
            if (RestoreMarkers.Any(body.Contains)) return CommitKind.Restore;
            return CommitKind.Other;
        }
    }

    /// <summary>The computer that made the commit, parsed from GitSync's messages; null otherwise.</summary>
    public string? Machine
    {
        get
        {
            if (Body is not { } body) return null;
            switch (Kind)
            {
                case CommitKind.Merge:
                    var open = body.LastIndexOfAny(['（', '(']);
                    var close = body.LastIndexOfAny(['）', ')']);
                    return open >= 0 && close > open ? body[(open + 1)..close] : null;
                case CommitKind.AutoSync:
                    return FirstIndex(body, AutoSyncMarkers) is { } a ? body[..a] : null;
                case CommitKind.Restore:
                    return FirstIndex(body, RestoreMarkers) is { } r ? body[..r] : null;
                default:
                    return null;
            }
        }
    }

    public string Source => Machine ?? Author;

    public string Title => Kind switch
    {
        CommitKind.AutoSync => L.T("自动同步", "Auto sync"),
        CommitKind.Merge => L.T("合并来自 GitHub 的更新", "Merged updates from GitHub"),
        CommitKind.Restore => (Body ?? "")[(Machine is { } m ? Math.Min(m.Length + 1, (Body ?? "").Length) : 0)..].Trim(),
        _ => Subject,
    };

    static int? FirstIndex(string text, string[] markers) =>
        markers.Select(m => text.IndexOf(m, StringComparison.Ordinal)).Where(i => i >= 0).Cast<int?>().FirstOrDefault();
}

public sealed record HistoryChange(string Status, string Path, string? OldPath = null)
{
    public string DisplayStatus => Status switch
    {
        "A" => L.T("新增", "Added"),
        "D" => L.T("删除", "Deleted"),
        "R" => L.T("重命名", "Renamed"),
        "C" => L.T("复制", "Copied"),
        _ => L.T("修改", "Modified"),
    };
}

/// <summary>One version of a single file.</summary>
public sealed record FileVersion(HistoryCommit Commit, string Path, bool IsDeletion)
{
    public long? Size { get; set; }
}

/// <summary>A file that existed in the history but is gone from the current version.</summary>
public sealed record DeletedFile(string Path, HistoryCommit DeletedIn, string LastVersionCommit)
{
    public long? Size { get; set; }
}

/// <summary>The effect of moving the whole repository back to a commit.</summary>
public sealed class RestorePreview
{
    public List<string> Modified { get; } = [];
    public List<string> Restored { get; } = [];
    public List<string> Removed { get; } = [];
    public int Total => Modified.Count + Restored.Count + Removed.Count;
}

/// <summary>Read-only queries over a repository's history. Nothing here changes the repository.</summary>
public sealed class HistoryBrowser(GitClient client)
{
    public GitClient Client { get; } = client;
    public TimeSpan Timeout { get; set; } = TimeSpan.FromSeconds(60);

    /// <summary>Record separator, then hash, parents, commit time, author, subject.</summary>
    const string Format = "%x1e%H%x1f%P%x1f%ct%x1f%an%x1f%s";

    /// <summary>Commits on the first-parent line, newest first: the state right after each sync.</summary>
    public async Task<List<HistoryCommit>> TimelineAsync(int limit = 200, int skip = 0) =>
        ParseLog((await Git(["log", "--first-parent", "--diff-merges=first-parent", "-z", "--name-status", $"--format={Format}",
                             "-n", limit.ToString(), "--skip", skip.ToString(), "HEAD", "--"])).StdoutData);

    /// <summary>Paths of every file in a commit (the latest one by default), sorted for display.</summary>
    public async Task<List<string>> TrackedFilesAsync(string commit = "HEAD") =>
        StatusEntry.Fields((await Git(["ls-tree", "-r", "--name-only", "-z", commit])).StdoutData)
            .Order(StringComparer.Create(CultureInfo.CurrentCulture, CompareOptions.IgnoreCase)).ToList();

    /// <summary>Every committed version of a file, newest first, following renames.</summary>
    public async Task<List<FileVersion>> VersionsAsync(string path, int limit = 300)
    {
        var result = await Git(["log", "--follow", "-z", "--name-status", $"--format={Format}", "-n", limit.ToString(), "HEAD", "--", path]);
        var versions = new List<FileVersion>();
        foreach (var commit in ParseLog(result.StdoutData))
        {
            // With --follow the only change listed is the file itself, under its name at the time.
            if (commit.Changes.FirstOrDefault() is not { } change) continue;
            versions.Add(new FileVersion(commit, change.Path, change.Status == "D"));
        }
        var sizes = await BlobSizes(versions.Where(v => !v.IsDeletion).Select(v => (v.Commit.Id, v.Path)));
        foreach (var version in versions.Where(v => !v.IsDeletion))
            version.Size = sizes.GetValueOrDefault($"{version.Commit.Id}:{version.Path}");
        return versions;
    }

    /// <summary>Files deleted at some point and not in the latest commit, most recent deletion first.</summary>
    public async Task<List<DeletedFile>> DeletedFilesAsync(int scanLimit = 2000)
    {
        var result = await Git(["log", "--diff-filter=D", "-z", "--name-status", "--no-renames", $"--format={Format}",
                                "-n", scanLimit.ToString(), "HEAD", "--"]);
        var current = (await TrackedFilesAsync()).ToHashSet();
        var seen = new HashSet<string>();
        var files = new List<DeletedFile>();
        foreach (var commit in ParseLog(result.StdoutData))
        {
            if (commit.Parents.FirstOrDefault() is not { } parent) continue;
            foreach (var change in commit.Changes.Where(c => c.Status == "D"))
            {
                if (current.Contains(change.Path) || !seen.Add(change.Path)) continue;
                // Recreated on disk but not synced yet: restoring would overwrite the new file.
                if (File.Exists(FullPath(change.Path))) continue;
                files.Add(new DeletedFile(change.Path, commit, parent));
            }
        }
        var sizes = await BlobSizes(files.Select(f => (f.LastVersionCommit, f.Path)));
        foreach (var file in files) file.Size = sizes.GetValueOrDefault($"{file.LastVersionCommit}:{file.Path}");
        return files;
    }

    /// <summary>What restoring the whole repository to a commit would change, compared with the latest one.</summary>
    public async Task<RestorePreview> PreviewRestoreAsync(string commit)
    {
        var result = await Git(["diff", "--name-status", "--no-renames", "-z", "HEAD", commit, "--"]);
        var preview = new RestorePreview();
        foreach (var (status, path) in SyncEngine.ParseNameStatus(result.StdoutData))
        {
            switch (status)
            {
                case "A": preview.Restored.Add(path); break;
                case "D": preview.Removed.Add(path); break;
                default: preview.Modified.Add(path); break;
            }
        }
        return preview;
    }

    /// <summary>The raw bytes of a file as committed.</summary>
    public async Task<byte[]> ContentAsync(string path, string commit) =>
        (await Git(["cat-file", "blob", $"{commit}:{path}"], TimeSpan.FromSeconds(300))).StdoutData;

    /// <summary>Writes a version to a temporary folder (for preview or comparing). The repository is untouched.</summary>
    public async Task<string> ExportForPreviewAsync(string path, string commit, DateTimeOffset date)
    {
        var data = await ContentAsync(path, commit);
        var folder = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "GitSync-Compare", commit[..Math.Min(12, commit.Length)]);
        Directory.CreateDirectory(folder);
        var target = System.IO.Path.Combine(folder, SyncEngine.CopyName(System.IO.Path.GetFileName(path), VersionLabel(date)));
        await File.WriteAllBytesAsync(target, data);
        return target;
    }

    /// <summary>
    /// Saves a version next to today's file as "name (2026-11-01 1530 版本).ext" without touching
    /// the original. Returns the repository-relative path of the copy; the next sync uploads it.
    /// </summary>
    public async Task<string> SaveCopyAsync(string path, string commit, DateTimeOffset date, string? besides = null)
    {
        var data = await ContentAsync(path, commit);
        var anchor = besides ?? path;
        var slash = anchor.LastIndexOf('/');
        var directory = slash >= 0 ? anchor[..slash] : "";
        var name = slash >= 0 ? anchor[(slash + 1)..] : anchor;
        var label = VersionLabel(date);
        var folder = FullPath(directory);
        var candidate = SyncEngine.CopyName(name, label);
        for (var counter = 2; File.Exists(System.IO.Path.Combine(folder, candidate)); counter++)
            candidate = SyncEngine.CopyName(name, $"{label} {counter}");
        Directory.CreateDirectory(folder);
        await using (var stream = new FileStream(System.IO.Path.Combine(folder, candidate), FileMode.CreateNew)) await stream.WriteAsync(data);
        return directory.Length == 0 ? candidate : $"{directory}/{candidate}";
    }

    /// <summary>The sync point just before a commit (its first parent) and whether the file existed there.</summary>
    public async Task<(string Commit, DateTimeOffset Date, bool HasFile)?> PreviousSyncPointAsync(string before, string path)
    {
        var parent = await Client.RunAsync(["log", "-n", "1", "--format=%H%x1f%ct", $"{before}~1"], Timeout);
        var fields = parent.Stdout.Trim().Split('\u001f');
        if (!parent.Succeeded || fields.Length != 2 || !long.TryParse(fields[1], out var seconds)) return null;
        var exists = await Client.RunAsync(["cat-file", "-e", $"{fields[0]}:{path}"], Timeout);
        return (fields[0], DateTimeOffset.FromUnixTimeSeconds(seconds).ToLocalTime(), exists.Succeeded);
    }

    /// <summary>What the latest sync point changed: path → 'A' (added) or 'M' (modified), and its time.</summary>
    public async Task<(DateTimeOffset? Date, Dictionary<string, char> Changes)> LastSyncChangesAsync()
    {
        var changes = new Dictionary<string, char>();
        var head = await Client.RunAsync(["log", "-n", "1", "--format=%ct", "HEAD"], Timeout);
        if (!head.Succeeded || !long.TryParse(head.Stdout.Trim(), out var seconds)) return (null, changes);
        var date = DateTimeOffset.FromUnixTimeSeconds(seconds).ToLocalTime();
        var diff = await Client.RunAsync(["diff", "--name-status", "--no-renames", "-z", "HEAD~1", "HEAD"], Timeout);
        if (!diff.Succeeded) return (date, changes);
        foreach (var (status, path) in SyncEngine.ParseNameStatus(diff.StdoutData))
        {
            if (status == "A") changes[path] = 'A';
            else if (status is "M" or "T") changes[path] = 'M';
        }
        return (date, changes);
    }

    public static string VersionLabel(DateTimeOffset date) =>
        date.ToLocalTime().ToString("yyyy-MM-dd HHmm", CultureInfo.InvariantCulture) + L.T(" 版本", " version");

    /// <summary>Parses <c>git log -z --name-status --format=Format</c> output.</summary>
    public static List<HistoryCommit> ParseLog(byte[] data)
    {
        var commits = new List<HistoryCommit>();
        foreach (var record in Encoding.UTF8.GetString(data).Split('\u001e', StringSplitOptions.RemoveEmptyEntries))
        {
            var headerEnd = record.IndexOf('\0');
            var header = headerEnd >= 0 ? record[..headerEnd] : record;
            var fields = header.Split('\u001f');
            if (fields.Length < 5 || !long.TryParse(fields[2], out var seconds)) continue;
            var commit = new HistoryCommit(fields[0], fields[1].Split(' ', StringSplitOptions.RemoveEmptyEntries),
                                           DateTimeOffset.FromUnixTimeSeconds(seconds).ToLocalTime(), fields[3],
                                           string.Join('\u001f', fields[4..]));
            if (headerEnd >= 0) commit = commit with { Changes = ParseChanges(record[(headerEnd + 1)..]) };
            commits.Add(commit);
        }
        return commits;
    }

    static List<HistoryChange> ParseChanges(string data)
    {
        var tokens = data.Split('\0');
        var changes = new List<HistoryChange>();
        for (var i = 0; i < tokens.Length;)
        {
            // Each commit's list starts on a new line; status letters never contain one.
            var status = tokens[i++].Trim('\n', '\r');
            if (status.Length == 0 || !char.IsLetter(status[0])) continue;
            var letter = status[0];
            var pathCount = letter is 'R' or 'C' ? 2 : 1;
            if (i + pathCount > tokens.Length) break;
            changes.Add(pathCount == 2
                ? new HistoryChange(letter.ToString(), tokens[i + 1], tokens[i])
                : new HistoryChange(letter.ToString(), tokens[i]));
            i += pathCount;
        }
        return changes;
    }

    /// <summary>Sizes of commit:path blobs in one cat-file call, keyed by "commit:path".</summary>
    async Task<Dictionary<string, long?>> BlobSizes(IEnumerable<(string Commit, string Path)> objects)
    {
        var keys = objects.Select(o => $"{o.Commit}:{o.Path}").Where(k => !k.Contains('\n')).ToList();
        var sizes = new Dictionary<string, long?>();
        if (keys.Count == 0) return sizes;
        var result = await Client.RunAsync(["cat-file", "--batch-check=%(objectsize)"], Timeout, Encoding.UTF8.GetBytes(string.Join("\n", keys) + "\n"));
        if (!result.Succeeded) return sizes;
        var lines = result.Stdout.Split('\n');
        for (var i = 0; i < keys.Count && i < lines.Length; i++)
            if (long.TryParse(lines[i].Trim(), out var size)) sizes[keys[i]] = size;
        return sizes;
    }

    string FullPath(string relative) => System.IO.Path.Combine(Client.RepositoryPath, relative.Replace('/', System.IO.Path.DirectorySeparatorChar));

    async Task<ProcessResult> Git(IReadOnlyList<string> args, TimeSpan? timeout = null)
    {
        var result = await Client.RunAsync(args, timeout ?? Timeout);
        if (!result.Succeeded) throw SyncFailure.From(result, SyncStage.History, "git " + string.Join(" ", args.Select(ProcessResult.Quote)));
        return result;
    }
}
