using System.Text.Json;
using System.Text.Json.Serialization;

namespace GitSync.Core;

/// <summary>A failure as stored with the repository (the exception itself isn't serializable).</summary>
public sealed class FailureRecord
{
    public FailureKind Kind { get; set; }
    public SyncStage Stage { get; set; }
    public string Command { get; set; } = "";
    public int? ExitCode { get; set; }
    public string Stderr { get; set; } = "";
    public string Message { get; set; } = "";
    public string Suggestion { get; set; } = "";
    public DateTimeOffset Date { get; set; }

    public static FailureRecord From(SyncFailure f) => new()
    {
        Kind = f.Kind, Stage = f.Stage, Command = f.Command, ExitCode = f.ExitCode, Stderr = f.Stderr,
        Message = f.Explanation, Suggestion = f.Suggestion, Date = f.Date,
    };

    public SyncFailure ToFailure() => new(Kind, Stage, Command, ExitCode, Stderr, Message, Suggestion) { Date = Date };
}

/// <summary>A repository the user added. Removing it never touches the folder or GitHub.</summary>
public sealed class RepositoryConfig
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Path { get; set; } = "";
    public string DisplayName { get; set; } = "";
    public bool AutoSyncEnabled { get; set; } = true;
    public DateTimeOffset AddedAt { get; set; } = DateTimeOffset.Now;
    public DateTimeOffset? LastSyncAt { get; set; }
    public DateTimeOffset? LastAttemptAt { get; set; }
    public SyncStatus LastStatus { get; set; } = SyncStatus.NotSynced;
    public string? LastMessage { get; set; }
    public FailureRecord? LastFailure { get; set; }
    public List<ConflictFile> ConflictFiles { get; set; } = [];
    /// <summary>Set when a conflict was detected; automatic sync skips the repository until resolved.</summary>
    public bool PausedForConflict { get; set; }
    /// <summary>What the folder was last seen as, to recognise it after it moved: origin URL and a commit.</summary>
    public string? KnownRemote { get; set; }
    public string? KnownCommit { get; set; }
    /// <summary>The folder's NTFS file ID, which survives moves and renames on the same drive.</summary>
    public string? FileId { get; set; }

    public RepositoryConfig Clone() => (RepositoryConfig)MemberwiseClone();
}

public sealed class AppSettings
{
    public static readonly int[] PresetIntervals = [1, 3, 5, 10, 15, 30, 60];

    public int IntervalMinutes { get; set; } = 5;
    public int MaxConcurrentSyncs { get; set; } = 2;
    public List<string> IgnorePatterns { get; set; } = [.. IgnoreRules.DefaultPatterns];
    public int LargeFileLimitMB { get; set; } = 100;
    public string? CustomGitPath { get; set; }
    /// <summary>"system", "zh" or "en".</summary>
    public string Language { get; set; } = "system";
    public bool StartAtLogin { get; set; } = true;
    public bool SyncOnWake { get; set; } = true;
    /// <summary>Renaming a repository's folder renames its GitHub repository to match.</summary>
    public bool RenameRemoteWithFolder { get; set; } = true;
    public bool NotifyOnFailure { get; set; } = true;
    public bool NotifyOnConflict { get; set; } = true;
    public bool NotifyOnAuthProblem { get; set; } = true;
    public bool NotifyOnChanges { get; set; }
    /// <summary>Main window size and position, restored at the next launch.</summary>
    public int[]? WindowBounds { get; set; }
    /// <summary>Manual sidebar order (repository IDs).</summary>
    public string Sort { get; set; } = "manual";

    public AppSettings Clone()
    {
        var copy = (AppSettings)MemberwiseClone();
        copy.IgnorePatterns = [.. IgnorePatterns];
        return copy;
    }
}

public sealed class PersistedState
{
    public int Version { get; set; } = 1;
    public AppSettings Settings { get; set; } = new();
    public List<RepositoryConfig> Repositories { get; set; } = [];
}

[JsonConverter(typeof(JsonStringEnumConverter<LogLevel>))]
public enum LogLevel { Info, Success, Warning, Error }

public static class LogLevelExtensions
{
    public static string DisplayName(this LogLevel level) => level switch
    {
        LogLevel.Info => L.T("信息", "Info"),
        LogLevel.Success => L.T("成功", "Success"),
        LogLevel.Warning => L.T("警告", "Warning"),
        _ => L.T("错误", "Error"),
    };
}

public sealed class SyncLogEntry
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public DateTimeOffset Date { get; set; } = DateTimeOffset.Now;
    public Guid? RepositoryId { get; set; }
    public string RepositoryName { get; set; } = "";
    public string Stage { get; set; } = "";
    public LogLevel Level { get; set; }
    public string Result { get; set; } = "";
    public int? ExitCode { get; set; }
    public string? Detail { get; set; }
    public double? Duration { get; set; }

    [JsonIgnore]
    public string CopyText
    {
        get
        {
            var text = $"[{Date:yyyy-MM-dd HH:mm:ss}] {RepositoryName} · {Stage} · {Level.DisplayName()}\n{Result}";
            if (ExitCode is { } code) text += L.T($"\n退出码：{code}", $"\nExit code: {code}");
            if (Duration is { } seconds) text += L.T($"\n耗时：{seconds:0.00} 秒", $"\nTook {seconds:0.00} s");
            if (!string.IsNullOrEmpty(Detail)) text += "\n\n" + Detail;
            return text;
        }
    }
}

[JsonSourceGenerationOptions(WriteIndented = true, PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase,
                             DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull)]
[JsonSerializable(typeof(PersistedState))]
[JsonSerializable(typeof(List<SyncLogEntry>))]
public sealed partial class GitSyncJson : JsonSerializerContext;

/// <summary>Atomic JSON file storage in %APPDATA%\GitSync.</summary>
public static class StateStore
{
    public static string Folder { get; set; } =
        System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "GitSync");

    public static string StatePath => System.IO.Path.Combine(Folder, "state.json");
    public static string LogPath => System.IO.Path.Combine(Folder, "logs.json");

    public static PersistedState LoadState()
    {
        try
        {
            if (!File.Exists(StatePath)) return new PersistedState { Version = 2 };
            var state = JsonSerializer.Deserialize(File.ReadAllText(StatePath), GitSyncJson.Default.PersistedState) ?? new PersistedState();
            // A transient status saved mid-sync (the app was killed) is not a real result.
            foreach (var repo in state.Repositories.Where(r => r.LastStatus.IsActive())) repo.LastStatus = SyncStatus.NotSynced;
            state.Version = 2;
            return state;
        }
        catch
        {
            // Keep the unreadable file for inspection and start fresh.
            try { File.Copy(StatePath, StatePath + ".broken", overwrite: true); } catch { }
            return new PersistedState { Version = 2 };
        }
    }

    public static void SaveState(PersistedState state) => WriteAtomic(StatePath, JsonSerializer.Serialize(state, GitSyncJson.Default.PersistedState));

    public static List<SyncLogEntry> LoadLogs()
    {
        try
        {
            return File.Exists(LogPath) ? JsonSerializer.Deserialize(File.ReadAllText(LogPath), GitSyncJson.Default.ListSyncLogEntry) ?? [] : [];
        }
        catch
        {
            return [];
        }
    }

    public static void SaveLogs(List<SyncLogEntry> entries) => WriteAtomic(LogPath, JsonSerializer.Serialize(entries, GitSyncJson.Default.ListSyncLogEntry));

    static void WriteAtomic(string path, string content)
    {
        Directory.CreateDirectory(System.IO.Path.GetDirectoryName(path)!);
        var temporary = path + ".tmp";
        File.WriteAllText(temporary, content);
        File.Move(temporary, path, overwrite: true);
    }
}

/// <summary>Serialises work per repository and caps how many repositories sync at once.</summary>
public sealed class SyncCoordinator(int maxConcurrent = 2)
{
    readonly HashSet<Guid> running = [];
    readonly object gate = new();
    SemaphoreSlim slots = new(Math.Max(1, maxConcurrent));

    public void SetMaxConcurrent(int value)
    {
        lock (gate) slots = new SemaphoreSlim(Math.Max(1, value));
    }

    public bool IsRunning(Guid id)
    {
        lock (gate) return running.Contains(id);
    }

    /// <summary>Runs the operation unless the same repository is already queued or running (then returns default).</summary>
    public async Task<T?> RunAsync<T>(Guid id, Func<Task<T>> operation) where T : class
    {
        SemaphoreSlim semaphore;
        lock (gate)
        {
            if (!running.Add(id)) return null;
            semaphore = slots;
        }
        await semaphore.WaitAsync();
        try
        {
            return await operation();
        }
        finally
        {
            semaphore.Release();
            lock (gate) running.Remove(id);
        }
    }
}
