using GitSync.App.Services;
using GitSync.App.Views;
using GitSync.Core;
using Microsoft.UI.Dispatching;
using Windows.Networking.Connectivity;

namespace GitSync.App;

/// <summary>Runtime state of one repository (not saved).</summary>
public sealed class RepoRuntime
{
    public RepositoryInfo? Info { get; set; }
    public SyncPhase? Phase { get; set; }
    public bool IsSyncing { get; set; }
    public IReadOnlyList<string> Warnings { get; set; } = [];
    public IReadOnlyList<SyncStepRecord> LastSteps { get; set; } = [];
    public RepositoryUsage? Usage { get; set; }
    public bool MeasuringUsage { get; set; }
    /// <summary>Set when the folder was found in the Recycle Bin.</summary>
    public string? RecycledPath { get; set; }
    public bool Downloading { get; set; }
}

public enum SyncTrigger { ManualSingle, ManualAll, Scheduled, Startup, Wake, NetworkRestored, ConflictResolution, Restore, Enabled }

public static class SyncTriggerExtensions
{
    public static bool IsManual(this SyncTrigger trigger) =>
        trigger is SyncTrigger.ManualSingle or SyncTrigger.ManualAll or SyncTrigger.ConflictResolution or SyncTrigger.Restore;

    public static string DisplayName(this SyncTrigger trigger) => trigger switch
    {
        SyncTrigger.ManualSingle or SyncTrigger.ManualAll => L.T("手动同步", "Manual sync"),
        SyncTrigger.Scheduled => L.T("定时同步", "Scheduled sync"),
        SyncTrigger.Startup => L.T("启动同步", "Startup sync"),
        SyncTrigger.Wake => L.T("唤醒后同步", "Sync after wake"),
        SyncTrigger.NetworkRestored => L.T("网络恢复后同步", "Sync after reconnecting"),
        SyncTrigger.ConflictResolution => L.T("解决冲突", "Resolve conflicts"),
        SyncTrigger.Restore => L.T("恢复历史版本", "Restore"),
        _ => L.T("开启自动同步", "Auto Sync turned on"),
    };
}

/// <summary>
/// Everything the interface shows and does: the repositories, their sync state, the schedule,
/// GitHub sign-in, logs and notifications. Lives on the UI thread; views listen to <see cref="Changed"/>.
/// </summary>
public sealed partial class AppModel
{
    public AppSettings Settings { get; private set; } = new();
    public List<RepositoryConfig> Repositories { get; } = [];
    public Dictionary<Guid, RepoRuntime> Runtime { get; } = [];
    public GitEnvironment? Git { get; private set; }
    public string? GitProblem { get; private set; }
    public bool IsOnline { get; private set; } = true;
    public DateTimeOffset? NextSyncDate { get; private set; }
    public List<SyncLogEntry> Logs { get; private set; } = [];
    public AuthService Auth { get; } = new();
    public Notifications Notifications { get; } = new();

    /// <summary>Something changed; views refresh (the argument is the repository, or null for everything).</summary>
    public event Action<Guid?>? Changed;

    readonly SyncCoordinator coordinator = new();
    readonly DispatcherQueue queue = DispatcherQueue.GetForCurrentThread();
    DispatcherQueueTimer? scheduler;
    DispatcherQueueTimer? logSaver;
    bool shuttingDown;

    public AppModel()
    {
        DispatcherQueueExtensions.Queue = queue;
        Auth.Changed += () => Notify(null);
    }

    public RepositoryConfig? Repository(Guid id) => Repositories.FirstOrDefault(r => r.Id == id);
    public RepoRuntime State(Guid id) => Runtime.TryGetValue(id, out var state) ? state : Runtime[id] = new RepoRuntime();
    public int AutoSyncCount => Repositories.Count(r => r.AutoSyncEnabled && !r.PausedForConflict);

    public void Notify(Guid? id) => RunOnUi(() => Changed?.Invoke(id));

    void RunOnUi(Action action)
    {
        if (queue.HasThreadAccess) action();
        else queue.TryEnqueue(() => action());
    }

    // MARK: Startup and shutdown

    public async Task StartAsync()
    {
        var state = StateStore.LoadState();
        Settings = state.Settings;
        Repositories.AddRange(state.Repositories);
        Logs = StateStore.LoadLogs();
        L.Language = Settings.Language == "system" ? L.DetectSystemLanguage() : Settings.Language;
        try { StartupService.SetEnabled(Settings.StartAtLogin); } catch { }
        Notify(null);

        await DetectGitAsync();
        await Auth.RefreshAsync(Git);
        foreach (var repo in Repositories.ToList()) await RefreshInfoAsync(repo.Id);

        NetworkInformation.NetworkStatusChanged += _ => RunOnUi(NetworkChanged);
        IsOnline = CheckOnline();
        Microsoft.Win32.SystemEvents.PowerModeChanged += (_, e) =>
        {
            if (e.Mode == Microsoft.Win32.PowerModes.Resume) RunOnUi(() => { if (Settings.SyncOnWake) SyncAll(SyncTrigger.Wake); });
        };

        RestartScheduler();
        SyncAll(SyncTrigger.Startup);
        _ = Task.Run(async () =>
        {
            await Task.Delay(TimeSpan.FromSeconds(20));
            RunOnUi(() => { foreach (var repo in Repositories) _ = RefreshUsageAsync(repo.Id); });
        });
    }

    public async Task ShutdownAsync()
    {
        shuttingDown = true;
        scheduler?.Stop();
        Persist();
        StateStore.SaveLogs(Logs);
        // Let running syncs finish (bounded), so no git process is cut off mid-commit.
        for (var i = 0; i < 40 && Runtime.Values.Any(r => r.IsSyncing); i++) await Task.Delay(250);
        Notifications.Unregister();
    }

    public async Task DetectGitAsync()
    {
        try
        {
            Git = await GitEnvironment.DetectAsync(Settings.CustomGitPath);
            GitProblem = null;
            Log(null, L.T("检测 Git", "Git"), LogLevel.Info, Git.Version + " · " + Git.GitPath);
        }
        catch (Exception error)
        {
            Git = null;
            GitProblem = error.Message;
            Log(null, L.T("检测 Git", "Git"), LogLevel.Error, L.T("未找到可用的 Git", "No working Git found"), detail: error.Message);
        }
        Notify(null);
    }

    static bool CheckOnline()
    {
        try
        {
            var level = NetworkInformation.GetInternetConnectionProfile()?.GetNetworkConnectivityLevel();
            return level is NetworkConnectivityLevel.InternetAccess or NetworkConnectivityLevel.ConstrainedInternetAccess;
        }
        catch
        {
            return true;
        }
    }

    void NetworkChanged()
    {
        var online = CheckOnline();
        if (online == IsOnline) return;
        IsOnline = online;
        Log(null, L.T("网络", "Network"), online ? LogLevel.Info : LogLevel.Warning,
            online ? L.T("网络已恢复", "Back online") : L.T("网络已断开，自动同步暂停", "Offline; auto sync pauses"));
        if (online) SyncAll(SyncTrigger.NetworkRestored, onlyFailed: true);
        Notify(null);
    }

    // MARK: Schedule

    public void SetInterval(int minutes)
    {
        minutes = Math.Clamp(minutes, 1, 24 * 60);
        if (minutes == Settings.IntervalMinutes) return;
        Settings.IntervalMinutes = minutes;
        Persist();
        Log(null, L.T("自动同步", "Auto sync"), LogLevel.Info, L.T($"同步间隔已改为 {minutes} 分钟", $"Sync interval set to {minutes} minutes"));
        RestartScheduler();
        Notify(null);
    }

    void RestartScheduler()
    {
        scheduler?.Stop();
        scheduler = queue.CreateTimer();
        scheduler.Interval = TimeSpan.FromMinutes(Settings.IntervalMinutes);
        scheduler.Tick += (_, _) =>
        {
            NextSyncDate = DateTimeOffset.Now + scheduler!.Interval;
            SyncAll(SyncTrigger.Scheduled);
        };
        scheduler.Start();
        NextSyncDate = DateTimeOffset.Now + scheduler.Interval;
        Notify(null);
    }

    public void SetAutoSync(Guid id, bool enabled)
    {
        if (Repository(id) is not { } repo || repo.AutoSyncEnabled == enabled) return;
        repo.AutoSyncEnabled = enabled;
        Persist();
        Log(id, L.T("设置", "Settings"), LogLevel.Info, enabled ? L.T($"{repo.DisplayName} 自动同步已开启", $"Auto Sync on for {repo.DisplayName}")
                                                               : L.T($"{repo.DisplayName} 自动同步已关闭", $"Auto Sync off for {repo.DisplayName}"));
        if (enabled) Sync(id, SyncTrigger.Enabled);
        Notify(id);
    }

    public void SetAutoSyncForAll(bool enabled)
    {
        var changed = Repositories.Where(r => r.AutoSyncEnabled != enabled).ToList();
        if (changed.Count == 0) return;
        foreach (var repo in changed) repo.AutoSyncEnabled = enabled;
        Persist();
        Log(null, L.T("自动同步", "Auto sync"), LogLevel.Info, enabled ? L.T($"已开启全部 {changed.Count} 个仓库的自动同步", $"Auto Sync on for all {changed.Count} repositories")
                                                                        : L.T("已暂停全部仓库的自动同步", "Auto Sync paused for all repositories"));
        if (enabled) foreach (var repo in changed) Sync(repo.Id, SyncTrigger.Enabled);
        Notify(null);
    }

    public string OverallStatusText
    {
        get
        {
            var syncing = Runtime.Values.Count(r => r.IsSyncing);
            if (syncing > 0) return L.T($"{syncing} 个仓库正在同步", $"Syncing {syncing} repositories");
            if (!IsOnline) return L.T("网络不可用", "Offline");
            var count = AutoSyncCount;
            return count == 0 ? L.T("自动同步已全部关闭", "Auto Sync is off") : L.T($"{count} 个仓库自动同步中", $"Auto Sync on for {count}");
        }
    }

    public SyncStatus DisplayStatus(RepositoryConfig repo)
    {
        var state = State(repo.Id);
        if (state.IsSyncing) return state.Phase?.Status() ?? SyncStatus.Checking;
        return repo.LastStatus;
    }

    // MARK: Syncing

    public void SyncAll(SyncTrigger trigger, bool onlyFailed = false)
    {
        foreach (var repo in Repositories.ToList())
        {
            if (repo.PausedForConflict) continue;
            if (trigger != SyncTrigger.ManualAll && !repo.AutoSyncEnabled) continue;
            if (onlyFailed && !repo.LastStatus.IsProblem()) continue;
            Sync(repo.Id, trigger);
        }
    }

    public void Sync(Guid id, SyncTrigger trigger)
    {
        if (shuttingDown || Repository(id) is not { } repo) return;
        var state = State(id);
        if (state.IsSyncing)
        {
            if (trigger.IsManual()) Log(id, L.T("同步", "Sync"), LogLevel.Info, L.T($"{repo.DisplayName} 正在同步中，已忽略重复请求", $"{repo.DisplayName} is already syncing"));
            return;
        }
        if (!FollowFolder(id))
        {
            var recycled = state.RecycledPath != null;
            Finish(id, null, new SyncFailure(FailureKind.FolderMissing, SyncStage.Inspect,
                message: recycled ? L.T($"文件夹在回收站中：{repo.DisplayName}", $"The folder is in the Recycle Bin: {repo.DisplayName}")
                                  : L.T($"本地文件夹不存在或已被移动：{repo.Path}", $"The folder is missing or was moved: {repo.Path}")), trigger);
            return;
        }
        if (Git is not { } git)
        {
            Finish(id, null, new SyncFailure(FailureKind.GitUnavailable, SyncStage.Preflight, stderr: GitProblem ?? ""), trigger);
            return;
        }
        if (!IsOnline)
        {
            repo.LastStatus = SyncStatus.NetworkUnavailable;
            repo.LastAttemptAt = DateTimeOffset.Now;
            repo.LastMessage = L.T("网络不可用，等待网络恢复后自动重试", "Offline; retries when the network is back");
            if (trigger.IsManual()) Log(id, L.T("同步", "Sync"), LogLevel.Warning, L.T($"{repo.DisplayName}：网络不可用，未执行同步", $"{repo.DisplayName}: offline, not synced"));
            Notify(id);
            return;
        }

        state.IsSyncing = true;
        state.Phase = null;
        Notify(id);
        _ = RunSync(id, repo.Path, git, trigger);
    }

    async Task RunSync(Guid id, string path, GitEnvironment git, SyncTrigger trigger, bool retriedAfterClosing = false)
    {
        var options = MakeOptions();
        var credential = await Auth.CredentialForGitAsync(git);
        var engine = new SyncEngine(new GitClient(path, git, credential), options);
        var report = await coordinator.RunAsync(id, () => engine.SyncAsync(phase => RunOnUi(() => { State(id).Phase = phase; Notify(id); })));
        if (report == null)
        {
            State(id).IsSyncing = false;
            Notify(id);
            return;
        }

        // Windows: a document open in Word/Excel/PowerPoint can't be replaced. Close the unchanged ones,
        // sync again, then open them again; ask about documents with unsaved edits.
        if (report.Failure?.Kind == FailureKind.FileLocked && !retriedAfterClosing)
        {
            var open = OfficeDocuments.OpenDocumentsInside(path);
            var closed = open.Where(d => d.Saved && OfficeDocuments.Close(d) == null).ToList();
            if (closed.Count > 0)
            {
                Log(id, L.T("刷新打开的文档", "Open documents"), LogLevel.Info,
                    L.T($"暂时关闭 {closed.Count} 个已打开的文档以便更新", $"Closed {closed.Count} open document(s) so they can be updated"));
                await RunSync(id, path, git, trigger, retriedAfterClosing: true);
                foreach (var document in closed) OfficeDocuments.Open(document);
                return;
            }
            if (open.Any(d => !d.Saved))
                report.Failure.Suggestion = L.T("有文档在 Word、Excel 或 PowerPoint 中打开并且有未保存的修改。请先保存或关闭它们，再点「立即同步」。",
                                                "A document is open in Word, Excel or PowerPoint with unsaved changes. Save or close it, then click Sync Now.");
        }
        Finish(id, report, null, trigger);
    }

    SyncOptions MakeOptions()
    {
        var limit = (long)Math.Max(1, Settings.LargeFileLimitMB) * 1024 * 1024;
        var options = new SyncOptions
        {
            IgnorePatterns = Settings.IgnorePatterns,
            LargeFileLimitBytes = limit,
            LargeFileWarningBytes = Math.Min(50L * 1024 * 1024, limit / 2),
            MachineName = Environment.MachineName,
        };
        if (Auth.Identity is { } identity) options.FallbackIdentity = identity;
        return options;
    }

    void Finish(Guid id, SyncReport? report, SyncFailure? failure, SyncTrigger trigger)
    {
        var state = State(id);
        state.IsSyncing = false;
        state.Phase = null;
        if (Repository(id) is not { } repo) { Notify(null); return; }   // removed while syncing
        var previousStatus = repo.LastStatus;
        var previousKind = repo.LastFailure?.Kind;
        if (report != null)
        {
            if (report.Info != null)
            {
                state.Info = report.Info;
                repo.KnownRemote = report.Info.RemoteUrl ?? repo.KnownRemote;
            }
            state.Warnings = report.Warnings;
            state.LastSteps = report.Steps;
        }
        var steps = string.Join("\n", report?.Steps.Select(s => s.Line) ?? []);
        var warnings = string.Join("\n", report?.Warnings ?? []);
        var duration = report?.Duration.TotalSeconds;
        var now = DateTimeOffset.Now;
        var outcome = report?.Outcome ?? new SyncOutcome.Failure(failure ?? new SyncFailure(FailureKind.Unknown, SyncStage.Preflight));

        switch (outcome)
        {
            case SyncOutcome.Success success:
                var summary = success.Summary;
                repo.LastStatus = SyncStatus.Success;
                repo.LastSyncAt = repo.LastAttemptAt = now;
                repo.LastMessage = summary.Text;
                repo.LastFailure = null;
                repo.ConflictFiles = [];
                repo.PausedForConflict = false;
                Log(id, trigger.DisplayName(), LogLevel.Success,
                    trigger == SyncTrigger.Restore ? L.T($"{repo.DisplayName}：恢复完成，{summary.Text}", $"{repo.DisplayName}: restored, {summary.Text}")
                                                   : L.T($"{repo.DisplayName}：同步成功，{summary.Text}", $"{repo.DisplayName}: synced, {summary.Text}"),
                    detail: Join(warnings, steps), duration: duration);
                if (Settings.NotifyOnChanges && (summary.DownloadedCommits > 0 || summary.UploadedCommits > 0))
                    Notifications.Post(L.T($"{repo.DisplayName} 已同步", $"{repo.DisplayName} synced"), summary.Text);
                var filesChanged = summary.CommittedFiles > 0 || summary.DownloadedCommits > 0 || summary.RestoredFiles > 0;
                _ = RefreshUsageAsync(id, filesChanged: filesChanged);
                _ = FollowRemoteRenameAsync(id);
                if (report?.DownloadedFiles.Count > 0) RefreshOpenDocuments(id, report.DownloadedFiles);
                break;

            case SyncOutcome.NoChanges:
                repo.LastStatus = SyncStatus.NoChanges;
                repo.LastSyncAt = repo.LastAttemptAt = now;
                repo.LastMessage = L.T("本地与 GitHub 均无变化", "No changes here or on GitHub");
                repo.LastFailure = null;
                repo.PausedForConflict = false;
                repo.ConflictFiles = [];
                Log(id, trigger.DisplayName(), LogLevel.Info, L.T($"{repo.DisplayName}：无文件变化", $"{repo.DisplayName}: no changes"),
                    detail: Join(warnings, steps), duration: duration);
                _ = FollowRemoteRenameAsync(id);
                break;

            case SyncOutcome.Conflict conflict:
                repo.LastStatus = SyncStatus.Conflict;
                repo.LastAttemptAt = now;
                repo.ConflictFiles = conflict.Files.ToList();
                repo.PausedForConflict = true;
                repo.LastFailure = null;
                repo.LastMessage = L.T($"{conflict.Files.Count} 个文件存在冲突，自动同步已暂停", $"{conflict.Files.Count} file(s) conflict; Auto Sync paused");
                Log(id, trigger.DisplayName(), LogLevel.Warning, L.T($"{repo.DisplayName}：检测到冲突，已暂停该仓库的自动同步", $"{repo.DisplayName}: conflict found, Auto Sync paused"),
                    detail: string.Join("\n", conflict.Files.Select(f => $"{f.Path}: {f.Description}")) + "\n\n" + steps, duration: duration);
                if (Settings.NotifyOnConflict && previousStatus != SyncStatus.Conflict)
                    Notifications.Post(L.T($"{repo.DisplayName} 存在冲突", $"{repo.DisplayName} has a conflict"),
                                       L.T("同一文件在本机和 GitHub 上都被修改了，请打开 GitSync 选择保留哪个版本。", "A file changed both here and on GitHub. Open GitSync to choose what to keep."));
                break;

            case SyncOutcome.Failure f:
                var error = f.Error;
                repo.LastStatus = error.MappedStatus;
                repo.LastAttemptAt = now;
                repo.LastMessage = error.Explanation;
                repo.LastFailure = FailureRecord.From(error);
                Log(id, error.Stage.DisplayName(), error.Kind == FailureKind.Network ? LogLevel.Warning : LogLevel.Error,
                    $"{repo.DisplayName}：{error.Explanation}", error.ExitCode,
                    Join(error.FullReport, warnings, L.T("执行记录：\n", "Steps:\n") + steps), duration);
                var changed = previousStatus != error.MappedStatus || previousKind != error.Kind;
                if (error.MappedStatus == SyncStatus.NeedsAuth)
                {
                    Auth.HandleGitAuthFailure();
                    if (Settings.NotifyOnAuthProblem && changed)
                        Notifications.Post(L.T("GitHub 认证失败", "GitHub sign-in failed"),
                                           L.T($"{repo.DisplayName}：{error.Explanation}。请在设置中重新登录。", $"{repo.DisplayName}: {error.Explanation}. Sign in again in Settings."));
                }
                else if (error.MappedStatus != SyncStatus.NetworkUnavailable && Settings.NotifyOnFailure && changed)
                {
                    Notifications.Post(L.T($"{repo.DisplayName} 同步失败", $"{repo.DisplayName} didn't sync"), error.Explanation);
                }
                break;
        }
        Persist();
        Notify(id);
    }

    static string Join(params string[] parts) => string.Join("\n\n", parts.Where(p => !string.IsNullOrWhiteSpace(p)));

    // MARK: Conflicts, restore, revert

    public async Task ResolveConflictsAsync(Guid id, IReadOnlyDictionary<string, ConflictChoice> choices)
    {
        if (Repository(id) is not { } repo || Git is not { } git) return;
        await RunEngineOperation(id, L.T("解决冲突", "Resolve conflicts"), L.T($"开始解决 {repo.DisplayName} 的冲突", $"Resolving conflicts in {repo.DisplayName}"),
                                 SyncTrigger.ConflictResolution, engine => engine.ResolveConflictsAsync(choices, Progress(id)));
    }

    public Task RestoreAsync(Guid id, RestoreTarget target, string description)
    {
        var name = Repository(id)?.DisplayName ?? "";
        return RunEngineOperation(id, L.T("恢复历史版本", "Restore"), L.T($"开始恢复 {name}：{description}", $"Restoring {name}: {description}"),
                                  SyncTrigger.Restore, engine => engine.RestoreAsync(target, description, Progress(id)));
    }

    public Task RevertToCloudAsync(Guid id, IReadOnlyList<string> paths)
    {
        var name = Repository(id)?.DisplayName ?? "";
        var names = string.Join(L.ListSeparator, paths.Take(3)) + (paths.Count > 3 ? L.T($" 等 {paths.Count} 项", $" and {paths.Count - 3} more") : "");
        return RunEngineOperation(id, L.T("还原为云端版本", "Revert to GitHub version"),
                                  L.T($"开始将 {name} 中的 {names} 还原为 GitHub 上的版本", $"Reverting {names} in {name} to the GitHub version"),
                                  SyncTrigger.Restore, engine => engine.RevertToRemoteAsync(paths, Progress(id)));
    }

    Action<SyncPhase> Progress(Guid id) => phase => RunOnUi(() => { State(id).Phase = phase; Notify(id); });

    async Task RunEngineOperation(Guid id, string title, string message, SyncTrigger trigger, Func<SyncEngine, Task<SyncReport>> operation)
    {
        if (shuttingDown || Repository(id) is not { } repo || Git is not { } git) return;
        var state = State(id);
        if (state.IsSyncing)
        {
            ShowAlert?.Invoke(L.T("请稍候", "Please wait"), L.T($"{repo.DisplayName} 正在同步，完成后再试。", $"{repo.DisplayName} is syncing; try again when it's done."));
            return;
        }
        state.IsSyncing = true;
        state.Phase = null;
        Log(id, title, LogLevel.Info, message);
        Notify(id);
        var engine = new SyncEngine(new GitClient(repo.Path, git, await Auth.CredentialForGitAsync(git)), MakeOptions());
        var report = await coordinator.RunAsync(id, () => operation(engine));
        if (report != null) Finish(id, report, null, trigger);
        else { state.IsSyncing = false; Notify(id); }
    }

    public async Task<bool> AbortInProgressOperationAsync(Guid id)
    {
        if (Repository(id) is not { } repo || Git is not { } git) return false;
        try
        {
            var operation = await new SyncEngine(new GitClient(repo.Path, git)).AbortInProgressOperationAsync();
            Log(id, L.T("中止操作", "Abort"), LogLevel.Warning, operation is { } op ? L.T($"已中止 {op.DisplayName()}", $"Aborted the {op.DisplayName()}") : L.T("没有需要中止的操作", "Nothing to abort"));
            await RefreshInfoAsync(id);
            return true;
        }
        catch (SyncFailure failure)
        {
            ShowAlert?.Invoke(L.T("中止失败", "Couldn't abort"), failure.FullReport);
            return false;
        }
    }

    /// <summary>Shows a message in the main window (set by it).</summary>
    public Action<string, string>? ShowAlert { get; set; }

    // MARK: Info, usage

    public async Task RefreshInfoAsync(Guid id)
    {
        FollowFolder(id);
        if (Git is not { } git || Repository(id) is not { } repo || !Directory.Exists(repo.Path)) { Notify(id); return; }
        try
        {
            var info = await new RepositoryInspector(new GitClient(repo.Path, git)).InspectAsync();
            State(id).Info = info;
            repo.KnownRemote = info.RemoteUrl ?? repo.KnownRemote;
            if (repo.FileId == null) repo.FileId = FolderLocator.FileId(repo.Path);
            var head = await new GitClient(repo.Path, git).RunAsync(["rev-list", "--max-parents=0", "HEAD"], TimeSpan.FromSeconds(15));
            if (head.Succeeded) repo.KnownCommit = head.Stdout.Split('\n')[0].Trim();
        }
        catch (SyncFailure failure)
        {
            if (failure.Kind is FailureKind.NotARepository or FailureKind.FolderMissing)
            {
                repo.LastStatus = SyncStatus.Failed;
                repo.LastFailure = FailureRecord.From(failure);
                repo.LastMessage = failure.Explanation;
            }
        }
        Notify(id);
    }

    public async Task RefreshUsageAsync(Guid id, bool force = false, bool filesChanged = true)
    {
        if (Git is not { } git || Repository(id) is not { } repo || !Directory.Exists(repo.Path)) return;
        var state = State(id);
        if (state.MeasuringUsage) return;
        if (!force && !filesChanged && state.Usage != null && DateTimeOffset.Now - state.Usage.MeasuredAt < TimeSpan.FromHours(1)) return;
        state.MeasuringUsage = true;
        Notify(id);
        try
        {
            var reuse = !filesChanged && !force ? state.Usage?.FileBytes : null;
            state.Usage = await new RepositoryUsageScanner(new GitClient(repo.Path, git)).MeasureAsync(reuse);
        }
        catch { /* shown as unknown */ }
        state.MeasuringUsage = false;
        Notify(id);
    }

    public HistoryBrowser? HistoryBrowser(Guid id) =>
        Git is { } git && Repository(id) is { } repo ? new HistoryBrowser(new GitClient(repo.Path, git)) : null;

    /// <summary>Local changes not synced yet, as git status reports them.</summary>
    public async Task<List<StatusEntry>> PendingChangesAsync(Guid id)
    {
        if (Git is not { } git || Repository(id) is not { } repo) return [];
        var result = await new GitClient(repo.Path, git).RunAsync(["status", "--porcelain=v1", "-z", "--untracked-files=all"], TimeSpan.FromSeconds(60));
        return result.Succeeded ? StatusEntry.Parse(result.StdoutData).OrderBy(e => e.Path, StringComparer.CurrentCultureIgnoreCase).ToList() : [];
    }

    // MARK: Persistence and logs

    public void Persist()
    {
        try
        {
            StateStore.SaveState(new PersistedState { Version = 2, Settings = Settings, Repositories = Repositories });
        }
        catch (Exception error)
        {
            Logs.Insert(0, new SyncLogEntry { RepositoryName = "GitSync", Stage = L.T("配置", "Settings"), Level = LogLevel.Error,
                                              Result = L.T("保存配置失败", "Couldn't save settings"), Detail = error.Message });
        }
    }

    public void Log(Guid? id, string stage, LogLevel level, string result, int? exitCode = null, string? detail = null, double? duration = null)
    {
        RunOnUi(() =>
        {
            var name = id is { } repoId ? Repository(repoId)?.DisplayName ?? "GitSync" : "GitSync";
            Logs.Insert(0, new SyncLogEntry { RepositoryId = id, RepositoryName = name, Stage = stage, Level = level, Result = result,
                                              ExitCode = exitCode, Detail = detail, Duration = duration });
            if (Logs.Count > 3000) Logs.RemoveRange(3000, Logs.Count - 3000);
            ScheduleLogSave();
            LogsChanged?.Invoke();
        });
    }

    public event Action? LogsChanged;

    public void ClearLogs()
    {
        Logs.Clear();
        StateStore.SaveLogs(Logs);
        LogsChanged?.Invoke();
    }

    void ScheduleLogSave()
    {
        if (logSaver == null)
        {
            logSaver = queue.CreateTimer();
            logSaver.Interval = TimeSpan.FromSeconds(2);
            logSaver.IsRepeating = false;
            logSaver.Tick += (_, _) => { try { StateStore.SaveLogs(Logs); } catch { } };
        }
        logSaver.Stop();
        logSaver.Start();
    }

    public void UpdateSettings(Action<AppSettings> change)
    {
        var before = Settings.Clone();
        change(Settings);
        Persist();
        if (before.IntervalMinutes != Settings.IntervalMinutes) RestartScheduler();
        if (before.MaxConcurrentSyncs != Settings.MaxConcurrentSyncs) coordinator.SetMaxConcurrent(Settings.MaxConcurrentSyncs);
        if (before.CustomGitPath != Settings.CustomGitPath) _ = DetectGitAsync();
        if (before.StartAtLogin != Settings.StartAtLogin) { try { StartupService.SetEnabled(Settings.StartAtLogin); } catch { } }
        Notify(null);
    }
}
