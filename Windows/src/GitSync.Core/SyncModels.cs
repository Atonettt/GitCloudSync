using System.Text.Json.Serialization;

namespace GitSync.Core;

/// <summary>User-visible status of a repository.</summary>
[JsonConverter(typeof(JsonStringEnumConverter<SyncStatus>))]
public enum SyncStatus
{
    NotSynced, Pending, Checking, Downloading, Uploading, Success, NoChanges, Failed, NeedsAuth, Conflict, NetworkUnavailable,
}

public static class SyncStatusExtensions
{
    public static string DisplayName(this SyncStatus status) => status switch
    {
        SyncStatus.NotSynced => L.T("未同步", "Not synced"),
        SyncStatus.Pending => L.T("等待同步", "Waiting"),
        SyncStatus.Checking => L.T("正在检查", "Checking"),
        SyncStatus.Downloading => L.T("下载中", "Downloading"),
        SyncStatus.Uploading => L.T("上传中", "Uploading"),
        SyncStatus.Success => L.T("同步成功", "Synced"),
        SyncStatus.NoChanges => L.T("无文件变化", "No changes"),
        SyncStatus.Failed => L.T("同步失败", "Sync failed"),
        SyncStatus.NeedsAuth => L.T("需要认证", "Sign-in needed"),
        SyncStatus.Conflict => L.T("存在冲突", "Conflict"),
        SyncStatus.NetworkUnavailable => L.T("网络不可用", "Offline"),
        _ => status.ToString(),
    };

    public static bool IsActive(this SyncStatus status) =>
        status is SyncStatus.Pending or SyncStatus.Checking or SyncStatus.Downloading or SyncStatus.Uploading;

    public static bool IsProblem(this SyncStatus status) =>
        status is SyncStatus.Failed or SyncStatus.NeedsAuth or SyncStatus.Conflict or SyncStatus.NetworkUnavailable;
}

/// <summary>Fine-grained progress reported by the engine while it runs.</summary>
public enum SyncPhase { Checking, Downloading, Committing, Merging, Restoring, Uploading }

public static class SyncPhaseExtensions
{
    public static SyncStatus Status(this SyncPhase phase) => phase switch
    {
        SyncPhase.Checking or SyncPhase.Restoring => SyncStatus.Checking,
        SyncPhase.Downloading or SyncPhase.Merging => SyncStatus.Downloading,
        _ => SyncStatus.Uploading,
    };

    public static string DisplayName(this SyncPhase phase) => phase switch
    {
        SyncPhase.Checking => L.T("正在检查", "Checking"),
        SyncPhase.Downloading => L.T("正在获取远程更新", "Getting updates from GitHub"),
        SyncPhase.Committing => L.T("正在提交本地修改", "Saving local changes"),
        SyncPhase.Merging => L.T("正在整合远程更新", "Merging updates"),
        SyncPhase.Restoring => L.T("正在恢复历史版本", "Restoring"),
        SyncPhase.Uploading => L.T("正在上传", "Uploading"),
        _ => phase.ToString(),
    };
}

[JsonConverter(typeof(JsonStringEnumConverter<SyncStage>))]
public enum SyncStage { Preflight, IgnoreRules, Fetch, Stage, Commit, Merge, Push, ConflictResolution, Restore, History, Inspect, Auth }

public static class SyncStageExtensions
{
    public static string DisplayName(this SyncStage stage) => stage switch
    {
        SyncStage.Preflight => L.T("同步前检查", "Preflight check"),
        SyncStage.IgnoreRules => L.T("应用忽略规则", "Ignore rules"),
        SyncStage.Fetch => L.T("获取远程更新", "Fetching updates"),
        SyncStage.Stage => L.T("检测本地修改", "Finding local changes"),
        SyncStage.Commit => L.T("提交本地修改", "Saving local changes"),
        SyncStage.Merge => L.T("整合远程更新", "Merging updates"),
        SyncStage.Push => L.T("上传到 GitHub", "Uploading to GitHub"),
        SyncStage.ConflictResolution => L.T("解决冲突", "Resolving conflicts"),
        SyncStage.Restore => L.T("恢复历史版本", "Restoring"),
        SyncStage.History => L.T("读取历史版本", "Reading history"),
        SyncStage.Inspect => L.T("读取仓库信息", "Reading repository"),
        SyncStage.Auth => L.T("GitHub 认证", "GitHub sign-in"),
        _ => stage.ToString(),
    };
}

[JsonConverter(typeof(JsonStringEnumConverter<FailureKind>))]
public enum FailureKind
{
    Authentication, RepositoryNotFound, Network, ServerUnavailable, Timeout, FolderMissing, PermissionDenied,
    NotARepository, NoRemote, DetachedHead, UnbornWithRemote, OperationInProgress, IndexLocked, LargeFile,
    MissingIdentity, PushRejected, MergeBlocked, UnrelatedHistories, GitUnavailable, FileLocked, Unknown,
}

/// <summary>A failed sync step with everything needed to explain it.</summary>
public sealed class SyncFailure : Exception
{
    public FailureKind Kind { get; set; }
    public SyncStage Stage { get; set; }
    public string Command { get; set; } = "";
    public int? ExitCode { get; set; }
    public string Stderr { get; set; } = "";
    public string Explanation { get; set; } = "";
    public string Suggestion { get; set; } = "";
    public DateTimeOffset Date { get; set; } = DateTimeOffset.Now;

    public override string Message => Explanation;

    [JsonConstructor]
    public SyncFailure() { }

    public SyncFailure(FailureKind kind, SyncStage stage, string command = "", int? exitCode = null, string stderr = "",
                       string? message = null, string? suggestion = null)
    {
        Kind = kind;
        Stage = stage;
        Command = command;
        ExitCode = exitCode;
        Stderr = stderr;
        Explanation = message ?? GitErrorClassifier.Message(kind, stage);
        Suggestion = suggestion ?? GitErrorClassifier.Suggestion(kind);
    }

    public static SyncFailure From(ProcessResult result, SyncStage stage, string command)
    {
        var kind = GitErrorClassifier.Classify(result.Stderr + "\n" + result.Stdout, result.TimedOut);
        var stderr = result.Stderr.Trim();
        if (stderr.Length == 0) stderr = result.Stdout.Trim();
        if (result.TimedOut)
            stderr = L.T($"（操作超时，已在 {(int)result.Duration.TotalSeconds} 秒后终止）\n",
                         $"(Timed out and stopped after {(int)result.Duration.TotalSeconds} s)\n") + stderr;
        if (stderr.Length > 8000) stderr = stderr[..8000];
        return new SyncFailure(kind, stage, command, result.ExitCode, stderr);
    }

    /// <summary>GitHub could not be reached; local work is unaffected and a later sync can finish the job.</summary>
    [JsonIgnore]
    public bool IsConnectivity => Kind is FailureKind.Network or FailureKind.Timeout or FailureKind.ServerUnavailable;

    [JsonIgnore]
    public SyncStatus MappedStatus => Kind switch
    {
        FailureKind.Authentication => SyncStatus.NeedsAuth,
        FailureKind.Network => SyncStatus.NetworkUnavailable,
        FailureKind.OperationInProgress => SyncStatus.Conflict,
        _ => SyncStatus.Failed,
    };

    /// <summary>Text suitable for the clipboard / bug reports.</summary>
    [JsonIgnore]
    public string FullReport => L.T(
        $"阶段：{Stage.DisplayName()}\n说明：{Explanation}\n命令：{(Command.Length == 0 ? "-" : Command)}\n退出码：{ExitCode?.ToString() ?? "-"}\n时间：{Date:yyyy-MM-dd HH:mm:ss}\nGit 输出：\n{(Stderr.Length == 0 ? "（无）" : Stderr)}\n\n处理建议：{Suggestion}",
        $"Stage: {Stage.DisplayName()}\nWhat happened: {Explanation}\nCommand: {(Command.Length == 0 ? "-" : Command)}\nExit code: {ExitCode?.ToString() ?? "-"}\nTime: {Date:yyyy-MM-dd HH:mm:ss}\nGit output:\n{(Stderr.Length == 0 ? "(none)" : Stderr)}\n\nWhat to do: {Suggestion}");
}

/// <summary>A file Git could not merge automatically.</summary>
public sealed record ConflictFile(string Path, bool LocalExists, bool RemoteExists)
{
    public string Description => (LocalExists, RemoteExists) switch
    {
        (true, true) => L.T("本地与远程都修改了此文件", "Changed both here and on GitHub"),
        (true, false) => L.T("远程删除了此文件，本地修改了它", "Deleted on GitHub, changed here"),
        (false, true) => L.T("本地删除了此文件，远程修改了它", "Deleted here, changed on GitHub"),
        _ => L.T("双方都删除或重命名了此文件", "Deleted or renamed on both sides"),
    };
}

public enum ConflictChoice { KeepLocal, KeepRemote, KeepBoth }

public static class ConflictChoiceExtensions
{
    public static string DisplayName(this ConflictChoice choice) => choice switch
    {
        ConflictChoice.KeepLocal => L.T("保留本地", "Keep Mine"),
        ConflictChoice.KeepRemote => L.T("使用远程", "Use GitHub's"),
        _ => L.T("保留两者", "Keep Both"),
    };
}

public enum InProgressOperation { Merge, Rebase, CherryPick, Revert }

public static class InProgressOperationExtensions
{
    public static string DisplayName(this InProgressOperation op) => op switch
    {
        InProgressOperation.Merge => L.T("合并 (merge)", "merge"),
        InProgressOperation.Rebase => L.T("变基 (rebase)", "rebase"),
        InProgressOperation.CherryPick => L.T("拣选 (cherry-pick)", "cherry-pick"),
        _ => L.T("还原 (revert)", "revert"),
    };

    public static string GitCommand(this InProgressOperation op) => op switch
    {
        InProgressOperation.Merge => "merge",
        InProgressOperation.Rebase => "rebase",
        InProgressOperation.CherryPick => "cherry-pick",
        _ => "revert",
    };
}

public sealed record SyncSummary(int CommittedFiles, int DownloadedCommits, int UploadedCommits, int RestoredFiles = 0)
{
    public string Text
    {
        get
        {
            var parts = new List<string>();
            if (RestoredFiles > 0) parts.Add(L.T($"恢复 {RestoredFiles} 个文件", $"restored {RestoredFiles} file(s)"));
            if (CommittedFiles > 0) parts.Add(L.T($"提交 {CommittedFiles} 个文件", $"saved {CommittedFiles} file(s)"));
            if (DownloadedCommits > 0) parts.Add(L.T($"下载 {DownloadedCommits} 个提交", $"downloaded {DownloadedCommits} commit(s)"));
            if (UploadedCommits > 0) parts.Add(L.T($"上传 {UploadedCommits} 个提交", $"uploaded {UploadedCommits} commit(s)"));
            return parts.Count == 0 ? L.T("已是最新", "Up to date") : L.Join(parts);
        }
    }
}

public sealed record SyncStepRecord(SyncStage Stage, string Command, int ExitCode, double Duration, bool TimedOut, string Output)
{
    public string Line => L.T(
        $"[{Stage.DisplayName()}] {Command} → {(TimedOut ? "超时" : $"退出码 {ExitCode}")}，{Duration:0.00} 秒",
        $"[{Stage.DisplayName()}] {Command} → {(TimedOut ? "timed out" : $"exit {ExitCode}")}, {Duration:0.00} s");
}

public abstract record SyncOutcome
{
    public sealed record Success(SyncSummary Summary) : SyncOutcome;
    public sealed record NoChanges : SyncOutcome;
    public sealed record Conflict(IReadOnlyList<ConflictFile> Files) : SyncOutcome;
    public sealed record Failure(SyncFailure Error) : SyncOutcome;
}

public sealed class SyncReport
{
    public required SyncOutcome Outcome { get; init; }
    public IReadOnlyList<SyncStepRecord> Steps { get; init; } = [];
    public IReadOnlyList<string> Warnings { get; init; } = [];
    public RepositoryInfo? Info { get; init; }
    public DateTimeOffset StartedAt { get; init; }
    public TimeSpan Duration { get; init; }
    /// <summary>Files GitHub's version changed on disk during this run, relative to the repository.</summary>
    public IReadOnlyList<string> DownloadedFiles { get; init; } = [];

    public SyncStatus Status => Outcome switch
    {
        SyncOutcome.Success => SyncStatus.Success,
        SyncOutcome.NoChanges => SyncStatus.NoChanges,
        SyncOutcome.Conflict => SyncStatus.Conflict,
        SyncOutcome.Failure f => f.Error.MappedStatus,
        _ => SyncStatus.Failed,
    };

    public SyncSummary? Summary => (Outcome as SyncOutcome.Success)?.Summary;
    public SyncFailure? Failure => (Outcome as SyncOutcome.Failure)?.Error;
    public bool IsNoChanges => Outcome is SyncOutcome.NoChanges;
    public string DebugText => string.Join("\n", Steps.Select(s => s.Line + "\n" + s.Output)) + "\n" + Failure?.FullReport;
}
