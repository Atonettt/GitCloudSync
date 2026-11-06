using System.Diagnostics;
using System.Text;

namespace GitSync.Core;

/// <summary>Result of a finished (or timed-out) child process.</summary>
public sealed record ProcessResult(
    string ExecutablePath,
    IReadOnlyList<string> Arguments,
    int ExitCode,
    byte[] StdoutData,
    byte[] StderrData,
    TimeSpan Duration,
    bool TimedOut)
{
    public string Stdout => Encoding.UTF8.GetString(StdoutData);
    public string Stderr => Encoding.UTF8.GetString(StderrData);
    public bool Succeeded => ExitCode == 0 && !TimedOut;

    public string CommandLine =>
        string.Join(" ", new[] { Path.GetFileNameWithoutExtension(ExecutablePath) }.Concat(Arguments.Select(Quote)));

    public static string Quote(string value)
    {
        if (value.Length == 0) return "\"\"";
        return value.Any(c => char.IsWhiteSpace(c) || c is '"' or '\'' or '&' or '|' or '<' or '>' or '^')
            ? "\"" + value.Replace("\"", "\\\"") + "\""
            : value;
    }
}

public sealed class ProcessLaunchException(string executable, string reason)
    : Exception(L.T($"无法启动 {executable}：{reason}", $"Couldn't start {executable}: {reason}"))
{
    public string Executable { get; } = executable;
}

/// <summary>
/// Runs external programs without a console window or terminal. stdin is closed unless data is
/// given, so nothing can wait for input; a timeout kills the whole process tree.
/// </summary>
public static class ProcessRunner
{
    public static async Task<ProcessResult> RunAsync(
        string executable,
        IReadOnlyList<string> arguments,
        string? workingDirectory = null,
        IReadOnlyDictionary<string, string>? environment = null,
        byte[]? stdin = null,
        TimeSpan? timeout = null,
        CancellationToken cancellationToken = default)
    {
        var info = new ProcessStartInfo(executable)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = true,
        };
        foreach (var argument in arguments) info.ArgumentList.Add(argument);
        if (workingDirectory != null) info.WorkingDirectory = workingDirectory;
        if (environment != null)
        {
            info.Environment.Clear();
            foreach (var (key, value) in environment) info.Environment[key] = value;
        }

        using var process = new Process { StartInfo = info };
        var started = Stopwatch.StartNew();
        try
        {
            if (!process.Start()) throw new ProcessLaunchException(executable, "Process.Start returned false");
        }
        catch (Exception error) when (error is not ProcessLaunchException)
        {
            throw new ProcessLaunchException(executable, error.Message);
        }

        var stdoutTask = ReadAllAsync(process.StandardOutput.BaseStream);
        var stderrTask = ReadAllAsync(process.StandardError.BaseStream);
        _ = Task.Run(async () =>
        {
            try
            {
                if (stdin != null) await process.StandardInput.BaseStream.WriteAsync(stdin, CancellationToken.None);
            }
            catch (IOException) { /* the child closed its input early */ }
            finally
            {
                try { process.StandardInput.Close(); } catch { /* already gone */ }
            }
        }, CancellationToken.None);

        var timedOut = false;
        using (var limit = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken))
        {
            limit.CancelAfter(timeout ?? TimeSpan.FromSeconds(60));
            try
            {
                await process.WaitForExitAsync(limit.Token);
            }
            catch (OperationCanceledException)
            {
                timedOut = !cancellationToken.IsCancellationRequested;
                try { process.Kill(entireProcessTree: true); } catch { /* exited meanwhile */ }
                try { await process.WaitForExitAsync(CancellationToken.None).WaitAsync(TimeSpan.FromSeconds(5)); } catch { }
                cancellationToken.ThrowIfCancellationRequested();
            }
        }

        // A grandchild (credential helper, ssh) may keep the pipes open; never wait forever.
        var stdout = await stdoutTask.WaitAsync(TimeSpan.FromSeconds(3)).ContinueWith(t => t.IsCompletedSuccessfully ? t.Result : []);
        var stderr = await stderrTask.WaitAsync(TimeSpan.FromSeconds(3)).ContinueWith(t => t.IsCompletedSuccessfully ? t.Result : []);

        return new ProcessResult(executable, arguments.ToArray(), timedOut ? -1 : process.ExitCode,
                                 stdout, stderr, started.Elapsed, timedOut);
    }

    private static async Task<byte[]> ReadAllAsync(Stream stream)
    {
        using var buffer = new MemoryStream();
        await stream.CopyToAsync(buffer);
        return buffer.ToArray();
    }
}
