namespace GitSync.Core;

/// <summary>
/// Where git lives and the environment every git call runs with: every interactive prompt is
/// turned off, so a missing credential produces an error instead of a hung process.
/// </summary>
public sealed record GitEnvironment(string GitPath, string Version, IReadOnlyDictionary<string, string> Environment)
{
    static readonly string[] UnixSearchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"];

    static IEnumerable<string> WindowsSearchPaths()
    {
        var programFiles = System.Environment.GetFolderPath(System.Environment.SpecialFolder.ProgramFiles);
        var programFilesX86 = System.Environment.GetFolderPath(System.Environment.SpecialFolder.ProgramFilesX86);
        var local = System.Environment.GetFolderPath(System.Environment.SpecialFolder.LocalApplicationData);
        foreach (var root in new[] { programFiles, programFilesX86, Path.Combine(local, "Programs") })
        {
            if (!string.IsNullOrEmpty(root)) yield return Path.Combine(root, "Git", "cmd");
        }
    }

    public static Dictionary<string, string> BuildEnvironment(IDictionary<string, string>? baseEnvironment = null)
    {
        var env = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        if (baseEnvironment != null)
        {
            foreach (var (key, value) in baseEnvironment) env[key] = value;
        }
        else
        {
            foreach (System.Collections.DictionaryEntry entry in System.Environment.GetEnvironmentVariables())
                env[(string)entry.Key] = (string?)entry.Value ?? "";
        }

        var extra = OperatingSystem.IsWindows() ? WindowsSearchPaths() : UnixSearchPaths;
        var existing = (env.GetValueOrDefault("PATH") ?? "").Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries);
        env["PATH"] = string.Join(Path.PathSeparator, existing.Concat(extra.Where(p => !existing.Contains(p))));

        // Never wait for input.
        env["GIT_TERMINAL_PROMPT"] = "0";
        env["GCM_INTERACTIVE"] = "never";
        env["GH_PROMPT_DISABLED"] = "1";
        env["GIT_EDITOR"] = "true";   // Git for Windows runs it through its own sh
        env["GIT_MERGE_AUTOEDIT"] = "no";
        env.Remove("GIT_ASKPASS");
        env.Remove("SSH_ASKPASS");
        if (!env.ContainsKey("GIT_SSH_COMMAND")) env["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes -o ConnectTimeout=20";

        // Abort transfers that stall (< 1 KB/s for 60 s).
        env["GIT_HTTP_LOW_SPEED_LIMIT"] = "1000";
        env["GIT_HTTP_LOW_SPEED_TIME"] = "60";

        // Don't fight GitHub Desktop over index.lock for read-only commands.
        env["GIT_OPTIONAL_LOCKS"] = "0";

        // English messages so errors can be classified reliably.
        env["LANG"] = "en_US.UTF-8";
        env["LC_ALL"] = "en_US.UTF-8";
        env.Remove("LANGUAGE");
        return env;
    }

    public static IEnumerable<string> CandidatePaths(string? customPath)
    {
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        if (!string.IsNullOrWhiteSpace(customPath) && seen.Add(customPath.Trim())) yield return customPath.Trim();
        var name = OperatingSystem.IsWindows() ? "git.exe" : "git";
        var path = BuildEnvironment()["PATH"];
        foreach (var dir in path.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        {
            var candidate = Path.Combine(dir, name);
            if (seen.Add(candidate)) yield return candidate;
        }
    }

    /// <summary>Finds a git that actually runs.</summary>
    public static async Task<GitEnvironment> DetectAsync(string? customPath = null)
    {
        var env = BuildEnvironment();
        var attempts = new List<string>();
        foreach (var path in CandidatePaths(customPath))
        {
            if (!File.Exists(path)) continue;
            try
            {
                var result = await ProcessRunner.RunAsync(path, ["--version"], environment: env, timeout: TimeSpan.FromSeconds(20));
                if (result.Succeeded && result.Stdout.StartsWith("git version"))
                    return new GitEnvironment(path, result.Stdout.Trim(), env);
                attempts.Add($"{path}: exit {result.ExitCode} {result.Stderr.Trim()}");
            }
            catch (Exception error)
            {
                attempts.Add($"{path}: {error.Message}");
            }
        }
        throw new GitNotFoundException(attempts);
    }

    /// <summary>Another command-line tool (for example <c>gh</c>) on the corrected PATH.</summary>
    public static string? FindExecutable(string name)
    {
        var fileName = OperatingSystem.IsWindows() && !name.EndsWith(".exe") ? name + ".exe" : name;
        foreach (var dir in BuildEnvironment()["PATH"].Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        {
            var candidate = Path.Combine(dir, fileName);
            if (File.Exists(candidate)) return candidate;
        }
        return null;
    }
}

public sealed class GitNotFoundException(IReadOnlyList<string> attempts) : Exception(Describe(attempts))
{
    public IReadOnlyList<string> Attempts { get; } = attempts;

    static string Describe(IReadOnlyList<string> attempts)
    {
        var text = L.T("未找到可用的 Git。请安装 Git for Windows（https://git-scm.com/download/win），或在设置中指定 git.exe 的位置。",
                       "No working Git was found. Install Git for Windows (https://git-scm.com/download/win), or choose git.exe in Settings.");
        if (attempts.Count > 0) text += L.T("\n\n尝试记录：\n", "\n\nTried:\n") + string.Join("\n", attempts);
        return text;
    }
}
