using System.Globalization;

namespace GitSync.Core;

public sealed record GitIdentity(string Name, string Email);

public sealed class SyncOptions
{
    public long LargeFileLimitBytes { get; set; } = 100L * 1024 * 1024;
    public long LargeFileWarningBytes { get; set; } = 50L * 1024 * 1024;
    public IReadOnlyList<string> IgnorePatterns { get; set; } = IgnoreRules.DefaultPatterns;
    public string MachineName { get; set; } = Environment.MachineName;
    /// <summary>Used only when the repository has no user.name / user.email configured.</summary>
    public GitIdentity FallbackIdentity { get; set; } = new("GitSync", "gitsync@users.noreply.github.com");
    public TimeSpan NetworkTimeout { get; set; } = TimeSpan.FromSeconds(300);
    public TimeSpan LocalTimeout { get; set; } = TimeSpan.FromSeconds(120);
    public int MaxPushRetries { get; set; } = 2;
}

/// <summary>What a restore brings back from history.</summary>
public abstract record RestoreTarget(string Commit)
{
    /// <summary>One file back to a committed version; <see cref="SourcePath"/> is its name in that commit.</summary>
    public sealed record File(string Path, string SourcePath, string Commit) : RestoreTarget(Commit);
    /// <summary>Every tracked file back to the state recorded in the commit.</summary>
    public sealed record Repository(string Commit) : RestoreTarget(Commit);
}

/// <summary>Thrown internally when a merge produced conflicts and was safely aborted.</summary>
sealed class ConflictDetected(IReadOnlyList<ConflictFile> files) : Exception
{
    public IReadOnlyList<ConflictFile> Files { get; } = files;
}

/// <summary>Collects step records and warnings for one run.</summary>
sealed class SyncSession
{
    public List<SyncStepRecord> Steps { get; } = [];
    public List<string> Warnings { get; } = [];
    public HashSet<string> DownloadedPaths { get; } = [];

    public void Record(ProcessResult result, SyncStage stage, string command)
    {
        var output = result.Stderr.Trim();
        if (output.Length == 0) output = result.Stdout.Trim();
        if (output.Length > 2000) output = output[..2000];
        Steps.Add(new SyncStepRecord(stage, command, result.ExitCode, result.Duration.TotalSeconds, result.TimedOut, output));
    }
}

/// <summary>
/// The two-way sync state machine for one repository, the same as the Mac app's. Safety rules:
/// local changes are committed before anything from GitHub is merged; a conflicting merge is
/// aborted immediately, leaving the local version on disk; never force-push, reset --hard or clean.
/// </summary>
public sealed class SyncEngine(GitClient client, SyncOptions? options = null)
{
    public GitClient Client { get; } = client;
    public SyncOptions Options { get; } = options ?? new SyncOptions();

    RepositoryInspector Inspector => new(Client);
    string Root => Client.RepositoryPath;

    // MARK: Public entry points

    public Task<SyncReport> SyncAsync(Action<SyncPhase>? progress = null) =>
        RunReporting(session => PerformSync(session, progress ?? (_ => { })));

    /// <summary>Re-runs the merge and applies the user's per-file choices.</summary>
    public Task<SyncReport> ResolveConflictsAsync(IReadOnlyDictionary<string, ConflictChoice> choices, Action<SyncPhase>? progress = null) =>
        RunReporting(session => PerformResolution(choices, session, progress ?? (_ => { })));

    /// <summary>
    /// Brings a file or the whole folder back to a committed version. Nothing is rewritten: local
    /// edits are committed first, a backup ref is created, and the old content becomes a new commit.
    /// </summary>
    public Task<SyncReport> RestoreAsync(RestoreTarget target, string description, Action<SyncPhase>? progress = null) =>
        RunReporting(session => PerformRestore(target, description, session, progress ?? (_ => { })));

    /// <summary>
    /// Puts files or folders back to how they are on GitHub now, discarding unsynced local changes
    /// (kept under a backup ref). Files that exist only on this computer are left alone.
    /// </summary>
    public Task<SyncReport> RevertToRemoteAsync(IReadOnlyList<string> paths, Action<SyncPhase>? progress = null) =>
        RunReporting(session => PerformRevertToRemote(paths, session, progress ?? (_ => { })));

    /// <summary>Writes GitHub's version of a conflicting file to a temporary folder for comparing.</summary>
    public async Task<string> ExportRemoteVersionAsync(string path)
    {
        var info = await Inspector.InspectAsync();
        var upstream = await Inspector.ResolveUpstreamAsync(info.Branch)
            ?? throw new SyncFailure(FailureKind.Unknown, SyncStage.ConflictResolution,
                                     message: L.T("找不到远程分支，无法导出远程版本", "GitHub has no branch to export from"));
        var result = await Client.RunAsync(["show", $"{upstream}:{path}"], Options.LocalTimeout);
        if (!result.Succeeded) throw SyncFailure.From(result, SyncStage.ConflictResolution, $"git show {upstream}:{path}");
        var folder = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "GitSync-Compare", Timestamp());
        Directory.CreateDirectory(folder);
        var target = System.IO.Path.Combine(folder, CopyName(System.IO.Path.GetFileName(path), L.T("远程版本", "GitHub version")));
        await System.IO.File.WriteAllBytesAsync(target, result.StdoutData);
        return target;
    }

    /// <summary>Aborts a merge / rebase / cherry-pick in progress. Only after the user confirmed.</summary>
    public async Task<InProgressOperation?> AbortInProgressOperationAsync()
    {
        var info = await Inspector.InspectAsync();
        if (info.InProgressOperation is not { } operation) return null;
        string[] args = [operation.GitCommand(), "--abort"];
        var result = await Client.RunAsync(args, Options.LocalTimeout);
        if (!result.Succeeded) throw SyncFailure.From(result, SyncStage.Preflight, "git " + string.Join(" ", args));
        return operation;
    }

    // MARK: Driver

    async Task<SyncReport> RunReporting(Func<SyncSession, Task<SyncOutcome>> body)
    {
        var session = new SyncSession();
        var start = DateTimeOffset.Now;
        SyncOutcome outcome;
        try
        {
            outcome = await body(session);
        }
        catch (ConflictDetected conflict)
        {
            outcome = new SyncOutcome.Conflict(conflict.Files);
        }
        catch (SyncFailure failure)
        {
            outcome = new SyncOutcome.Failure(failure);
        }
        catch (Exception error)
        {
            outcome = new SyncOutcome.Failure(new SyncFailure(FailureKind.Unknown, SyncStage.Preflight, stderr: error.Message));
        }
        RepositoryInfo? info = null;
        try { info = await Inspector.InspectAsync(); } catch { /* folder gone or not a repository */ }
        return new SyncReport
        {
            Outcome = outcome,
            Steps = session.Steps,
            Warnings = session.Warnings,
            Info = info,
            StartedAt = start,
            Duration = DateTimeOffset.Now - start,
            DownloadedFiles = session.DownloadedPaths.Order(StringComparer.Ordinal).ToList(),
        };
    }

    async Task<SyncOutcome> PerformSync(SyncSession session, Action<SyncPhase> progress)
    {
        progress(SyncPhase.Checking);
        var info = await Preflight();
        var branch = info.Branch ?? throw new SyncFailure(FailureKind.DetachedHead, SyncStage.Preflight);

        progress(SyncPhase.Downloading);
        await Fetch(session);

        var upstream = await Inspector.ResolveUpstreamAsync(branch);
        var adopted = 0;
        if (info.IsUnborn)
        {
            // Nothing committed here yet, but GitHub may already have content, possibly on a branch
            // with another name (whatever GitHub shows by default). Start from that.
            if (upstream == null)
            {
                await Git(["remote", "set-head", "origin", "--auto"], SyncStage.Fetch, session, Options.NetworkTimeout);
                upstream = await Inspector.RemoteDefaultBranchAsync();
            }
            if (upstream != null)
            {
                progress(SyncPhase.Merging);
                (branch, adopted) = await AdoptRemoteBranch(upstream, session);
            }
        }

        progress(SyncPhase.Committing);
        var committed = await CommitLocalChanges(session);
        var (downloaded, uploaded) = await IntegrateAndPush(branch, upstream, session, progress);
        downloaded += adopted;

        if (committed == 0 && downloaded == 0 && uploaded == 0) return new SyncOutcome.NoChanges();
        return new SyncOutcome.Success(new SyncSummary(committed, downloaded, uploaded));
    }

    /// <summary>Merges what is on GitHub and pushes, retrying when another computer pushed in between.</summary>
    async Task<(int Downloaded, int Uploaded)> IntegrateAndPush(string branch, string? upstream, SyncSession session, Action<SyncPhase> progress)
    {
        int downloaded = 0, uploaded = 0;
        var pushed = false;
        for (var attempt = 0; attempt <= Options.MaxPushRetries; attempt++)
        {
            if (attempt > 0)
            {
                progress(SyncPhase.Downloading);
                await Fetch(session);
                upstream = await Inspector.ResolveUpstreamAsync(branch);
            }

            if (upstream == null)
            {
                // The branch does not exist on GitHub yet: publish it.
                var hasCommits = (await Git(["rev-parse", "--verify", "--quiet", "HEAD"], SyncStage.Push, session)).Succeeded;
                if (!hasCommits) { pushed = true; break; }
                progress(SyncPhase.Uploading);
                var count = await Git(["rev-list", "--count", "HEAD"], SyncStage.Push, session);
                if (await Push("origin", branch, setUpstream: true, session))
                {
                    uploaded += int.TryParse(count.Stdout.Trim(), out var n) ? n : 0;
                    pushed = true;
                    break;
                }
                continue;
            }

            var (ahead, behind) = await Inspector.AheadBehindAsync(upstream);
            if (behind > 0)
            {
                progress(SyncPhase.Merging);
                await Merge(upstream, ahead, session);
                downloaded += behind;
                (ahead, behind) = await Inspector.AheadBehindAsync(upstream);
            }
            if (ahead == 0) { pushed = true; break; }

            progress(SyncPhase.Uploading);
            var (remote, remoteBranch) = Split(upstream);
            if (await Push(remote, remoteBranch, setUpstream: false, session))
            {
                uploaded += ahead;
                pushed = true;
                break;
            }
        }

        if (!pushed)
        {
            var last = session.Steps.LastOrDefault();
            throw new SyncFailure(FailureKind.PushRejected, SyncStage.Push, last?.Command ?? "git push", last?.ExitCode, last?.Output ?? "");
        }
        return (downloaded, uploaded);
    }

    async Task<SyncOutcome> PerformResolution(IReadOnlyDictionary<string, ConflictChoice> choices, SyncSession session, Action<SyncPhase> progress)
    {
        progress(SyncPhase.Checking);
        var info = await Preflight();
        var branch = info.Branch ?? throw new SyncFailure(FailureKind.DetachedHead, SyncStage.Preflight);

        progress(SyncPhase.Downloading);
        await Fetch(session);
        progress(SyncPhase.Committing);
        var committed = await CommitLocalChanges(session);

        var upstream = await Inspector.ResolveUpstreamAsync(branch)
            ?? throw new SyncFailure(FailureKind.Unknown, SyncStage.ConflictResolution,
                                     message: L.T("远程分支不存在，无需解决冲突，请直接同步", "GitHub has no branch to merge; just sync"));

        // A ref that keeps the pre-resolution local commit reachable forever.
        var backupRef = $"refs/gitcloud-sync/backup/{Timestamp()}";
        await GitChecked(["update-ref", backupRef, "HEAD"], SyncStage.ConflictResolution, session);
        session.Warnings.Add(L.T($"已创建备份引用 {backupRef}，可随时恢复解决冲突前的本地版本。",
                                 $"Created backup ref {backupRef} with the local version before the conflict was resolved."));

        var (ahead, behind) = await Inspector.AheadBehindAsync(upstream);
        var downloaded = 0;
        if (behind > 0)
        {
            progress(SyncPhase.Merging);
            string[] mergeArgs = ["merge", "--no-ff", "--no-commit", upstream];
            var result = await Git(mergeArgs, SyncStage.ConflictResolution, session, extraConfig: await IdentityConfig());
            if (!result.Succeeded)
            {
                var conflicts = await ConflictFiles();
                if (conflicts.Count == 0)
                {
                    await AbortMergeIfNeeded(session);
                    throw SyncFailure.From(result, SyncStage.ConflictResolution, "git " + string.Join(" ", mergeArgs));
                }
                if (conflicts.Any(c => !choices.ContainsKey(c.Path)))
                {
                    // New conflicts appeared since the user made their choices.
                    await AbortMergeIfNeeded(session);
                    throw new ConflictDetected(conflicts);
                }
                try
                {
                    foreach (var file in conflicts) await Apply(choices[file.Path], file, session);
                    var remaining = await Inspector.UnmergedPathsAsync();
                    if (remaining.Count > 0)
                        throw new SyncFailure(FailureKind.Unknown, SyncStage.ConflictResolution,
                                              message: L.T($"仍有未解决的冲突：{string.Join(L.ListSeparator, remaining)}",
                                                           $"Conflicts remain: {string.Join(L.ListSeparator, remaining)}"));
                }
                catch
                {
                    try { await AbortMergeIfNeeded(session); } catch { /* report the original error */ }
                    throw;
                }
            }
            if (RepositoryInspector.InProgress(info.GitDirectory) == InProgressOperation.Merge)
                await GitChecked(["commit", "--no-edit", "--quiet"], SyncStage.Commit, session, extraConfig: await IdentityConfig());
            downloaded = behind;
            (ahead, behind) = await Inspector.AheadBehindAsync(upstream);
        }

        var uploaded = 0;
        if (ahead > 0)
        {
            progress(SyncPhase.Uploading);
            var (remote, remoteBranch) = Split(upstream);
            if (!await Push(remote, remoteBranch, setUpstream: false, session))
                throw new SyncFailure(FailureKind.PushRejected, SyncStage.Push,
                                      message: L.T("冲突已在本地解决，但远程又有新提交", "The conflict was resolved here, but GitHub changed again"),
                                      suggestion: L.T("冲突解决结果已保存在本地提交中，请再次点击同步。", "The resolution is saved locally; sync again."));
            uploaded = ahead;
        }
        return new SyncOutcome.Success(new SyncSummary(committed, downloaded, uploaded));
    }

    async Task<SyncOutcome> PerformRestore(RestoreTarget target, string description, SyncSession session, Action<SyncPhase> progress)
    {
        progress(SyncPhase.Checking);
        var info = await Preflight();
        var branch = info.Branch ?? throw new SyncFailure(FailureKind.DetachedHead, SyncStage.Preflight);
        if (info.IsUnborn)
            throw new SyncFailure(FailureKind.Unknown, SyncStage.Restore, message: L.T("仓库还没有任何历史版本", "The repository has no history yet"));
        if (!(await Git(["rev-parse", "--verify", "--quiet", $"{target.Commit}^{{commit}}"], SyncStage.Restore, session)).Succeeded)
            throw new SyncFailure(FailureKind.Unknown, SyncStage.Restore, $"git rev-parse --verify {target.Commit}",
                                  message: L.T("找不到所选的历史版本", "The chosen version wasn't found"),
                                  suggestion: L.T("请关闭历史窗口后重新打开再试。", "Close the history window, open it again and retry."));

        // Start from the newest version so the restore is not undone by the next merge. Offline, the
        // restore still happens locally and is uploaded by a later sync.
        progress(SyncPhase.Downloading);
        SyncFailure? offline = null;
        try { await Fetch(session); }
        catch (SyncFailure failure) when (failure.IsConnectivity) { offline = failure; }

        progress(SyncPhase.Committing);
        var committed = await CommitLocalChanges(session);
        var downloaded = 0;
        if (offline == null && await Inspector.ResolveUpstreamAsync(branch) is { } current)
        {
            var (ahead, behind) = await Inspector.AheadBehindAsync(current);
            if (behind > 0)
            {
                progress(SyncPhase.Merging);
                await Merge(current, ahead, session);
                downloaded = behind;
            }
        }

        progress(SyncPhase.Restoring);
        var backupRef = $"refs/gitcloud-sync/backup/{Timestamp()}";
        await GitChecked(["update-ref", backupRef, "HEAD"], SyncStage.Restore, session);
        session.Warnings.Add(L.T($"已创建备份引用 {backupRef}，记录了恢复前的版本。", $"Created backup ref {backupRef} with the version before the restore."));
        await ApplyRestore(target, session);

        var staged = await GitChecked(["diff", "--cached", "--name-status", "-z"], SyncStage.Restore, session);
        var files = ParseNameStatus(staged.StdoutData);
        if (files.Count == 0)
            session.Warnings.Add(L.T("当前内容已经与所选版本相同，无需恢复。", "The content already matches that version."));
        else
            await GitChecked(["commit", "--quiet", "-m", RestoreMessage(description, files)], SyncStage.Commit, session,
                             extraConfig: await IdentityConfig());

        if (offline != null)
        {
            if (files.Count == 0 && committed == 0) return new SyncOutcome.NoChanges();
            offline.Explanation = L.T("已在本地恢复，但无法连接 GitHub", "Restored here, but GitHub can't be reached");
            offline.Suggestion = L.T("恢复结果已保存在本地提交中，联网后下次同步会自动上传。", "The restore is saved locally and uploads at the next sync.");
            throw offline;
        }

        var uploaded = 0;
        try
        {
            var result = await IntegrateAndPush(branch, await Inspector.ResolveUpstreamAsync(branch), session, progress);
            downloaded += result.Downloaded;
            uploaded = result.Uploaded;
        }
        catch (SyncFailure failure) when (failure.IsConnectivity)
        {
            failure.Explanation = L.T("已在本地恢复，但上传失败：", "Restored here, but the upload failed: ") + failure.Explanation;
            failure.Suggestion = L.T("恢复结果已保存在本地提交中，联网后下次同步会自动上传。", "The restore is saved locally and uploads at the next sync.");
            throw;
        }

        if (files.Count == 0 && committed == 0 && downloaded == 0 && uploaded == 0) return new SyncOutcome.NoChanges();
        return new SyncOutcome.Success(new SyncSummary(committed, downloaded, uploaded, files.Count));
    }

    async Task ApplyRestore(RestoreTarget target, SyncSession session)
    {
        switch (target)
        {
            case RestoreTarget.File file when file.Path == file.SourcePath:
                await GitChecked(["restore", $"--source={file.Commit}", "--staged", "--worktree", "--", $":(literal){file.Path}"],
                                 SyncStage.Restore, session);
                break;
            case RestoreTarget.File file:
                // The file had another name in that version: write the old content under today's name.
                var blob = await Client.RunAsync(["cat-file", "blob", $"{file.Commit}:{file.SourcePath}"], Options.LocalTimeout);
                if (!blob.Succeeded) throw SyncFailure.From(blob, SyncStage.Restore, $"git cat-file blob {file.Commit}:{file.SourcePath}");
                var full = FullPath(file.Path);
                Directory.CreateDirectory(System.IO.Path.GetDirectoryName(full)!);
                await System.IO.File.WriteAllBytesAsync(full, blob.StdoutData);
                await GitChecked(["add", "--", $":(literal){file.Path}"], SyncStage.Restore, session);
                break;
            case RestoreTarget.Repository repository:
                // Matches every tracked file to that commit; untracked and ignored files are left alone.
                await GitChecked(["restore", $"--source={repository.Commit}", "--staged", "--worktree", "--", ":/"],
                                 SyncStage.Restore, session, Options.LocalTimeout * 3);
                await DropRestoredIgnoredFiles(session);
                break;
        }
    }

    /// <summary>Old versions may contain files ignored today (an old .DS_Store); those are not brought back.</summary>
    async Task DropRestoredIgnoredFiles(SyncSession session)
    {
        var staged = await GitChecked(["diff", "--cached", "--name-only", "--diff-filter=A", "-z"], SyncStage.Restore, session);
        var added = StatusEntry.Fields(staged.StdoutData);
        if (added.Count == 0) return;
        var input = System.Text.Encoding.UTF8.GetBytes(string.Join("\0", added) + "\0");
        var check = await Client.RunAsync(["check-ignore", "--no-index", "-z", "--stdin"], Options.LocalTimeout, input);
        var ignored = StatusEntry.Fields(check.StdoutData);
        if (ignored.Count == 0) return;
        await GitChecked(["restore", "--source=HEAD", "--staged", "--worktree", "--", .. ignored.Select(p => $":(literal){p}")],
                         SyncStage.Restore, session);
        session.Warnings.Add(L.T($"以下文件属于忽略规则，未恢复：{string.Join(L.ListSeparator, ignored.Take(5))}",
                                 $"These files match the ignore rules and weren't restored: {string.Join(L.ListSeparator, ignored.Take(5))}"));
    }

    async Task<SyncOutcome> PerformRevertToRemote(IReadOnlyList<string> paths, SyncSession session, Action<SyncPhase> progress)
    {
        progress(SyncPhase.Checking);
        var info = await Preflight();
        var branch = info.Branch ?? throw new SyncFailure(FailureKind.DetachedHead, SyncStage.Preflight);
        progress(SyncPhase.Downloading);
        await Fetch(session);
        var upstream = await Inspector.ResolveUpstreamAsync(branch)
            ?? throw new SyncFailure(FailureKind.Unknown, SyncStage.Restore,
                                     message: L.T("GitHub 上还没有这个仓库的内容，无法还原", "GitHub has nothing for this repository yet"));
        var specs = paths.Select(p => $":(literal){p}").ToList();
        async Task<HashSet<string>> List(params string[] args) =>
            StatusEntry.Fields((await GitChecked([.. args, "--", .. specs], SyncStage.Restore, session)).StdoutData).ToHashSet();

        // What differs from GitHub, limited to files GitHub has; an untracked local file at a path
        // GitHub has would be overwritten, so it is skipped too.
        var differing = await List("diff", "--name-only", "--no-renames", "-z", upstream);
        var onGitHub = await List("ls-tree", "-r", "--name-only", "-z", upstream);
        var untracked = await List("ls-files", "--others", "--exclude-standard", "-z");
        var targets = differing.Intersect(onGitHub).Except(untracked).Order(StringComparer.Ordinal).ToList();
        var localOnly = untracked.Union(differing.Except(onGitHub)).Order(StringComparer.Ordinal).ToList();
        if (localOnly.Count > 0)
            session.Warnings.Add(L.T($"只在本机、GitHub 上没有的文件保持不变：{string.Join(L.ListSeparator, localOnly.Take(5))}",
                                     $"Files only on this computer were left as they are: {string.Join(L.ListSeparator, localOnly.Take(5))}"));
        if (targets.Count == 0)
        {
            session.Warnings.Add(L.T("所选内容已经和 GitHub 上一致，无需还原。", "The selection already matches GitHub."));
            return new SyncOutcome.NoChanges();
        }

        progress(SyncPhase.Restoring);
        // `stash create` records the local edits as a commit without touching anything.
        var stash = await GitChecked(["stash", "create"], SyncStage.Restore, session, extraConfig: await IdentityConfig());
        var snapshot = stash.Stdout.Trim();
        var backupRef = $"refs/gitcloud-sync/backup/{Timestamp()}";
        await GitChecked(["update-ref", backupRef, snapshot.Length == 0 ? "HEAD" : snapshot], SyncStage.Restore, session);
        session.Warnings.Add(L.T($"已创建备份引用 {backupRef}，记录了还原前的本地内容。", $"Created backup ref {backupRef} with the local content before the revert."));
        await GitChecked(["restore", $"--source={upstream}", "--staged", "--worktree", "--", .. targets.Select(t => $":(literal){t}")],
                         SyncStage.Restore, session, Options.LocalTimeout * 3);
        return new SyncOutcome.Success(new SyncSummary(0, 0, 0, targets.Count));
    }

    // MARK: Steps

    async Task<RepositoryInfo> Preflight()
    {
        var info = await Inspector.InspectAsync();
        if (info.IndexLocked)
            throw new SyncFailure(FailureKind.IndexLocked, SyncStage.Preflight,
                                  stderr: L.T($"存在 {info.GitDirectory}\\index.lock", $"{info.GitDirectory}\\index.lock exists"));
        if (info.InProgressOperation is { } operation)
        {
            var message = L.T($"仓库中有未完成的{operation.DisplayName()}操作", $"An unfinished {operation.DisplayName()} is in progress");
            if (info.UnmergedFiles.Count > 0)
                message += L.T($"，未解决的文件：{string.Join(L.ListSeparator, info.UnmergedFiles.Take(10))}",
                               $"; unresolved files: {string.Join(L.ListSeparator, info.UnmergedFiles.Take(10))}");
            throw new SyncFailure(FailureKind.OperationInProgress, SyncStage.Preflight, message: message);
        }
        if (info.UnmergedFiles.Count > 0)
            throw new SyncFailure(FailureKind.OperationInProgress, SyncStage.Preflight,
                                  message: L.T($"仓库中存在未解决的冲突文件：{string.Join(L.ListSeparator, info.UnmergedFiles.Take(10))}",
                                               $"Unresolved conflict files: {string.Join(L.ListSeparator, info.UnmergedFiles.Take(10))}"));
        if (info.IsDetached) throw new SyncFailure(FailureKind.DetachedHead, SyncStage.Preflight);
        if (info.RemoteUrl == null) throw new SyncFailure(FailureKind.NoRemote, SyncStage.Preflight);
        try
        {
            IgnoreRules.Apply(Options.IgnorePatterns, info.GitDirectory);
        }
        catch (Exception error)
        {
            throw new SyncFailure(FailureKind.PermissionDenied, SyncStage.IgnoreRules, stderr: error.Message);
        }
        return info;
    }

    Task Fetch(SyncSession session) => GitChecked(["fetch", "--prune", "origin"], SyncStage.Fetch, session, Options.NetworkTimeout);

    /// <summary>Stages everything (minus oversized files) and commits. Returns the number of files committed.</summary>
    async Task<int> CommitLocalChanges(SyncSession session)
    {
        var status = await GitChecked(["status", "--porcelain=v1", "-z", "--untracked-files=all"], SyncStage.Stage, session, Options.LocalTimeout);
        var entries = StatusEntry.Parse(status.StdoutData);
        if (entries.Count == 0) return 0;

        var excluded = new List<string>();
        foreach (var entry in entries.Where(e => !e.IsDeletion))
        {
            var file = new FileInfo(FullPath(entry.Path));
            if (!file.Exists) continue;
            if (file.Length > Options.LargeFileLimitBytes)
            {
                excluded.Add(entry.Path);
                session.Warnings.Add(L.T(
                    $"「{entry.Path}」大小 {FormatBytes(file.Length)}，超过上传上限 {FormatBytes(Options.LargeFileLimitBytes)}，已跳过（文件保留在本地）。建议移出仓库或使用 Git LFS。",
                    $"“{entry.Path}” is {FormatBytes(file.Length)}, over the {FormatBytes(Options.LargeFileLimitBytes)} limit, and was skipped (it stays here). Move it out or use Git LFS."));
            }
            else if (file.Length > Options.LargeFileWarningBytes)
            {
                session.Warnings.Add(L.T($"「{entry.Path}」大小 {FormatBytes(file.Length)}，接近 GitHub 100 MB 限制，上传可能较慢。",
                                         $"“{entry.Path}” is {FormatBytes(file.Length)}, close to GitHub's 100 MB limit; uploading may be slow."));
            }
        }

        await GitChecked(["add", "-A", "--", ".", .. excluded.Select(p => $":(exclude,literal){p}")], SyncStage.Stage, session, Options.LocalTimeout * 3);
        var staged = await GitChecked(["diff", "--cached", "--name-status", "-z"], SyncStage.Stage, session, Options.LocalTimeout);
        var files = ParseNameStatus(staged.StdoutData);
        if (files.Count == 0) return 0;

        await GitChecked(["commit", "--quiet", "-m", CommitMessage(files)], SyncStage.Commit, session, Options.LocalTimeout,
                         await IdentityConfig());
        return files.Count;
    }

    /// <summary>
    /// Checks out GitHub's branch in a repository without commits. Git refuses to overwrite local
    /// files: clashing files stop the sync with an explanation; others stay as local changes.
    /// </summary>
    async Task<(string Branch, int Downloaded)> AdoptRemoteBranch(string upstream, SyncSession session)
    {
        var (_, remoteBranch) = Split(upstream);
        string[] args = ["checkout", "--quiet", "-B", remoteBranch, "--track", upstream];
        var result = await Git(args, SyncStage.Merge, session, Options.LocalTimeout);
        if (!result.Succeeded)
            throw new SyncFailure(FailureKind.UnbornWithRemote, SyncStage.Merge, "git " + string.Join(" ", args), result.ExitCode, result.Stderr);
        var count = await Git(["rev-list", "--count", "HEAD"], SyncStage.Merge, session);
        return (remoteBranch, int.TryParse(count.Stdout.Trim(), out var n) ? n : 0);
    }

    async Task Merge(string upstream, int localAhead, SyncSession session)
    {
        var before = (await Git(["rev-parse", "--verify", "--quiet", "HEAD"], SyncStage.Merge, session)).Stdout.Trim();
        if (localAhead == 0)
        {
            await GitChecked(["merge", "--ff-only", "--quiet", upstream], SyncStage.Merge, session, Options.LocalTimeout);
            await RecordDownloadedPaths(before, session);
            return;
        }
        string[] args = ["merge", "--no-edit", "-m", L.T($"GitSync：合并来自 GitHub 的更新（{Options.MachineName}）",
                                                          $"GitSync: merged updates from GitHub ({Options.MachineName})"), upstream];
        var result = await Git(args, SyncStage.Merge, session, Options.LocalTimeout, await IdentityConfig());
        if (result.Succeeded)
        {
            await RecordDownloadedPaths(before, session);
            return;
        }
        var conflicts = await ConflictFiles();
        if (conflicts.Count > 0 || RepositoryInspector.InProgress(await GitDirectory()) == InProgressOperation.Merge)
        {
            await AbortMergeIfNeeded(session);
            throw new ConflictDetected(conflicts);
        }
        throw SyncFailure.From(result, SyncStage.Merge, $"git merge --no-edit {upstream}");
    }

    /// <summary>Notes the files a merge changed on disk (for refreshing documents open in other apps).</summary>
    async Task RecordDownloadedPaths(string before, SyncSession session)
    {
        if (before.Length == 0) return;
        var diff = await Git(["diff", "--name-only", "--no-renames", "-z", before, "HEAD"], SyncStage.Merge, session);
        if (!diff.Succeeded) return;
        foreach (var path in StatusEntry.Fields(diff.StdoutData)) session.DownloadedPaths.Add(path);
    }

    async Task<bool> Push(string remote, string remoteBranch, bool setUpstream, SyncSession session)
    {
        var args = new List<string> { "push", "--porcelain" };
        if (setUpstream) args.Add("--set-upstream");
        args.AddRange([remote, $"HEAD:refs/heads/{remoteBranch}"]);
        var result = await Git(args, SyncStage.Push, session, Options.NetworkTimeout);
        if (result.Succeeded) return true;
        // The remote moved between fetch and push: retried after fetching and merging again.
        var output = (result.Stdout + "\n" + result.Stderr).ToLowerInvariant();
        string[] raceMarkers = ["[rejected]", "non-fast-forward", "fetch first", "cannot lock ref", "stale info"];
        if (!result.TimedOut && raceMarkers.Any(output.Contains)) return false;
        throw SyncFailure.From(result, SyncStage.Push, "git " + string.Join(" ", args));
    }

    async Task Apply(ConflictChoice choice, ConflictFile file, SyncSession session)
    {
        var path = file.Path;
        async Task Checkout(string side)
        {
            await GitChecked(["checkout", side, "--", path], SyncStage.ConflictResolution, session);
            await GitChecked(["add", "--", path], SyncStage.ConflictResolution, session);
        }
        Task Remove() => GitChecked(["rm", "--quiet", "--", path], SyncStage.ConflictResolution, session);

        switch (choice)
        {
            case ConflictChoice.KeepLocal:
                await (file.LocalExists ? Checkout("--ours") : Remove());
                break;
            case ConflictChoice.KeepRemote:
                await (file.RemoteExists ? Checkout("--theirs") : Remove());
                break;
            default:
                switch ((file.LocalExists, file.RemoteExists))
                {
                    case (true, true):
                        await GitChecked(["checkout", "--ours", "--", path], SyncStage.ConflictResolution, session);
                        var remote = await GitChecked(["show", $":3:{path}"], SyncStage.ConflictResolution, session);
                        var copyPath = UniqueCopyPath(path);
                        var full = FullPath(copyPath);
                        Directory.CreateDirectory(System.IO.Path.GetDirectoryName(full)!);
                        await using (var stream = new FileStream(full, FileMode.CreateNew)) await stream.WriteAsync(remote.StdoutData);
                        await GitChecked(["add", "--", path, copyPath], SyncStage.ConflictResolution, session);
                        session.Warnings.Add(L.T($"「{path}」保留本地版本，远程版本另存为「{copyPath}」。",
                                                 $"Kept your version of “{path}”; GitHub's was saved as “{copyPath}”."));
                        break;
                    case (true, false): await Checkout("--ours"); break;
                    case (false, true): await Checkout("--theirs"); break;
                    default: await Remove(); break;
                }
                break;
        }
    }

    async Task AbortMergeIfNeeded(SyncSession session)
    {
        var gitDir = await GitDirectory();
        if (RepositoryInspector.InProgress(gitDir) != InProgressOperation.Merge) return;
        var result = await Git(["merge", "--abort"], SyncStage.Merge, session);
        if (!result.Succeeded || RepositoryInspector.InProgress(gitDir) == InProgressOperation.Merge)
            throw new SyncFailure(FailureKind.OperationInProgress, SyncStage.Merge, "git merge --abort", result.ExitCode, result.Stderr,
                                  L.T("检测到冲突后自动中止合并失败，仓库仍处于合并状态", "Aborting the conflicting merge failed; the repository is still merging"),
                                  L.T("为避免数据丢失，GitSync 没有执行任何其他清理。请在 GitHub Desktop 中查看并处理该仓库。",
                                      "To avoid losing data GitSync did nothing else. Check the repository in GitHub Desktop."));
    }

    // MARK: Helpers

    async Task<List<ConflictFile>> ConflictFiles()
    {
        var result = await Client.RunAsync(["ls-files", "-u", "-z"], Options.LocalTimeout);
        if (!result.Succeeded) return [];
        var stages = new Dictionary<string, HashSet<int>>();
        var order = new List<string>();
        foreach (var line in StatusEntry.Fields(result.StdoutData))
        {
            // "<mode> <sha> <stage>\t<path>"
            var tab = line.IndexOf('\t');
            if (tab < 0) continue;
            var meta = line[..tab].Split(' ');
            var path = line[(tab + 1)..];
            if (meta.Length != 3 || !int.TryParse(meta[2], out var stage)) continue;
            if (!stages.ContainsKey(path)) { order.Add(path); stages[path] = []; }
            stages[path].Add(stage);
        }
        return order.Select(p => new ConflictFile(p, stages[p].Contains(2), stages[p].Contains(3))).ToList();
    }

    async Task<IReadOnlyList<string>> IdentityConfig()
    {
        var email = await Client.RunAsync(["config", "--get", "user.email"], TimeSpan.FromSeconds(15));
        var name = await Client.RunAsync(["config", "--get", "user.name"], TimeSpan.FromSeconds(15));
        var config = new List<string>();
        if (!name.Succeeded || name.Stdout.Trim().Length == 0) config.AddRange(["-c", $"user.name={Options.FallbackIdentity.Name}"]);
        if (!email.Succeeded || email.Stdout.Trim().Length == 0) config.AddRange(["-c", $"user.email={Options.FallbackIdentity.Email}"]);
        return config;
    }

    async Task<string> GitDirectory() =>
        RepositoryInspector.NormalizePath((await Client.RunAsync(["rev-parse", "--absolute-git-dir"], TimeSpan.FromSeconds(15))).Stdout.Trim());

    string CommitMessage(IReadOnlyList<(string Status, string Path)> files)
    {
        var date = DateTime.Now.ToString("yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture);
        var lines = new List<string>
        {
            L.T($"GitSync：{Options.MachineName} 自动同步 {date}", $"GitSync: {Options.MachineName} auto-sync {date}"), "",
            L.T($"共 {files.Count} 个文件变更：", $"{files.Count} file(s) changed:"),
        };
        lines.AddRange(files.Take(30).Select(f => $"{f.Status}\t{f.Path}"));
        if (files.Count > 30) lines.Add(L.T($"……以及另外 {files.Count - 30} 个文件", $"…and {files.Count - 30} more"));
        return string.Join("\n", lines);
    }

    string RestoreMessage(string description, IReadOnlyList<(string Status, string Path)> files)
    {
        var lines = new List<string>
        {
            L.T($"GitSync：{Options.MachineName} 恢复{description}", $"GitSync: {Options.MachineName} restored {description}"), "",
            L.T($"共 {files.Count} 个文件：", $"{files.Count} file(s):"),
        };
        lines.AddRange(files.Take(30).Select(f => $"{f.Status}\t{f.Path}"));
        if (files.Count > 30) lines.Add(L.T($"……以及另外 {files.Count - 30} 个文件", $"…and {files.Count - 30} more"));
        return string.Join("\n", lines);
    }

    string UniqueCopyPath(string path)
    {
        var slash = path.LastIndexOf('/');
        var directory = slash >= 0 ? path[..slash] : "";
        var name = slash >= 0 ? path[(slash + 1)..] : path;
        var label = L.T($"远程版本 {Timestamp(true)}", $"GitHub version {Timestamp(true)}");
        var candidate = CopyName(name, label);
        for (var counter = 2; System.IO.File.Exists(FullPath(directory.Length == 0 ? candidate : $"{directory}/{candidate}")); counter++)
            candidate = CopyName(name, $"{label} {counter}");
        return directory.Length == 0 ? candidate : $"{directory}/{candidate}";
    }

    string FullPath(string relative) => System.IO.Path.Combine(Root, relative.Replace('/', System.IO.Path.DirectorySeparatorChar));

    public static string CopyName(string fileName, string label)
    {
        var ext = System.IO.Path.GetExtension(fileName);
        var stem = System.IO.Path.GetFileNameWithoutExtension(fileName);
        return ext.Length == 0 || stem.Length == 0 ? $"{fileName} ({label})" : $"{stem} ({label}){ext}";
    }

    public static (string Remote, string Branch) Split(string upstream)
    {
        var slash = upstream.IndexOf('/');
        return slash < 0 ? ("origin", upstream) : (upstream[..slash], upstream[(slash + 1)..]);
    }

    public static List<(string Status, string Path)> ParseNameStatus(byte[] data)
    {
        var fields = StatusEntry.Fields(data);
        var files = new List<(string, string)>();
        for (var i = 0; i < fields.Count;)
        {
            var status = fields[i++];
            // Renames / copies carry two paths.
            var pathCount = status.StartsWith('R') || status.StartsWith('C') ? 2 : 1;
            if (i + pathCount > fields.Count) break;
            files.Add((status[..1], fields[i + pathCount - 1]));
            i += pathCount;
        }
        return files;
    }

    public static string Timestamp(bool shortForm = false) =>
        DateTime.Now.ToString(shortForm ? "yyyy-MM-dd HHmm" : "yyyyMMdd-HHmmss", CultureInfo.InvariantCulture);

    public static string FormatBytes(long bytes)
    {
        string[] units = ["B", "KB", "MB", "GB", "TB"];
        double value = bytes;
        var unit = 0;
        while (value >= 1000 && unit < units.Length - 1) { value /= 1000; unit++; }
        return unit == 0 ? $"{bytes} B" : $"{value:0.#} {units[unit]}";
    }

    async Task<ProcessResult> Git(IReadOnlyList<string> args, SyncStage stage, SyncSession session, TimeSpan? timeout = null,
                                  IReadOnlyList<string>? extraConfig = null)
    {
        var command = "git " + string.Join(" ", args.Select(ProcessResult.Quote));
        ProcessResult result;
        try
        {
            result = await Client.RunAsync(args, timeout ?? Options.LocalTimeout, extraConfig: extraConfig);
        }
        catch (ProcessLaunchException error)
        {
            throw new SyncFailure(FailureKind.GitUnavailable, stage, command, stderr: error.Message);
        }
        session.Record(result, stage, command);
        return result;
    }

    async Task<ProcessResult> GitChecked(IReadOnlyList<string> args, SyncStage stage, SyncSession session, TimeSpan? timeout = null,
                                         IReadOnlyList<string>? extraConfig = null)
    {
        var result = await Git(args, stage, session, timeout, extraConfig);
        if (!result.Succeeded) throw SyncFailure.From(result, stage, "git " + string.Join(" ", args.Select(ProcessResult.Quote)));
        return result;
    }
}
