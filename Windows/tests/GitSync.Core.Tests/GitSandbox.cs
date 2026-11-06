using System.Text;
using GitSync.Core;

namespace GitSync.Core.Tests;

/// <summary>A temporary bare "GitHub" repository plus clones standing in for two computers.</summary>
public sealed class GitSandbox : IAsyncLifetime
{
    public string Root { get; } = Path.Combine(Path.GetTempPath(), "GitSyncTests-" + Guid.NewGuid().ToString("N"));
    public string Bare => Path.Combine(Root, "remote.git");
    public GitEnvironment Git { get; private set; } = null!;

    public async Task InitializeAsync()
    {
        Directory.CreateDirectory(Root);
        var git = await GitEnvironment.DetectAsync();
        var env = new Dictionary<string, string>(git.Environment) { ["GIT_CONFIG_NOSYSTEM"] = "1" };
        // Tests must not pick up the developer's proxy or credential helpers.
        foreach (var key in new[] { "HTTPS_PROXY", "HTTP_PROXY", "https_proxy", "http_proxy", "ALL_PROXY", "all_proxy" }) env.Remove(key);
        Git = git with { Environment = env };
    }

    public Task DisposeAsync()
    {
        try
        {
            foreach (var file in Directory.EnumerateFiles(Root, "*", SearchOption.AllDirectories))
                File.SetAttributes(file, FileAttributes.Normal);   // git marks objects read-only on Windows
            Directory.Delete(Root, recursive: true);
        }
        catch { /* best effort */ }
        return Task.CompletedTask;
    }

    /// <summary>Creates the bare remote with one initial commit on main.</summary>
    public async Task CreateRemote(Dictionary<string, string>? seedFiles = null)
    {
        await Run(["init", "--bare", "-b", "main", Bare], Root);
        var seed = Path.Combine(Root, "seed");
        await Run(["clone", Bare, seed], Root);
        await Configure(seed);
        foreach (var (name, content) in seedFiles ?? new() { ["README.md"] = "hello\n" }) Write(content, name, seed);
        await Run(["add", "-A"], seed);
        await Run(["commit", "-m", "initial"], seed);
        await Run(["push", "-u", "origin", "main"], seed);
    }

    public Task CreateEmptyRemote() => Run(["init", "--bare", "-b", "main", Bare], Root);

    public async Task<string> Clone(string name)
    {
        var path = Path.Combine(Root, name);
        await Run(["clone", Bare, path], Root);
        await Configure(path);
        return path;
    }

    public async Task Configure(string repo)
    {
        await Run(["config", "user.name", "Tester"], repo);
        await Run(["config", "user.email", "tester@example.com"], repo);
        await Run(["config", "commit.gpgsign", "false"], repo);
        await Run(["config", "core.autocrlf", "false"], repo);
    }

    public SyncEngine Engine(string repo, SyncOptions? options = null) => new(new GitClient(repo, Git), options);

    public async Task<ProcessResult> Run(IReadOnlyList<string> args, string directory)
    {
        var result = await ProcessRunner.RunAsync(Git.GitPath, ["-c", "core.quotepath=false", .. args], directory, Git.Environment,
                                                  timeout: TimeSpan.FromSeconds(60));
        if (!result.Succeeded) throw new InvalidOperationException($"git {string.Join(" ", args)} failed: {result.Stderr}");
        return result;
    }

    public static void Write(string content, string name, string repo)
    {
        var path = Path.Combine(repo, name);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, content, new UTF8Encoding(false));
    }

    public static void WriteBytes(byte[] data, string name, string repo)
    {
        var path = Path.Combine(repo, name);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllBytes(path, data);
    }

    public static string? Read(string name, string repo)
    {
        var path = Path.Combine(repo, name);
        return File.Exists(path) ? File.ReadAllText(path) : null;
    }

    public static bool Exists(string name, string repo) => File.Exists(Path.Combine(repo, name)) || Directory.Exists(Path.Combine(repo, name));

    /// <summary>Commit and push directly with git, simulating the other computer.</summary>
    public async Task CommitAndPush(Dictionary<string, string> files, string repo, string message = "remote change")
    {
        await Run(["pull", "--ff-only"], repo);
        foreach (var (name, content) in files) Write(content, name, repo);
        await Run(["add", "-A"], repo);
        await Run(["commit", "-m", message], repo);
        await Run(["push"], repo);
    }

    public async Task<List<string>> RemoteFiles(string branch = "main") =>
        (await Run(["ls-tree", "-r", "--name-only", branch], Bare)).Stdout.Split('\n', StringSplitOptions.RemoveEmptyEntries).ToList();

    public async Task<string> RemoteContent(string path) => (await Run(["show", $"main:{path}"], Bare)).Stdout;
}
