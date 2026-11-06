namespace GitSync.Core;

/// <summary>A GitHub token handed to git for HTTPS remotes on github.com.</summary>
public sealed record GitCredential(string Token, string Username = "x-access-token");

/// <summary>Runs git inside one repository with a safe environment.</summary>
public sealed class GitClient(string repositoryPath, GitEnvironment git, GitCredential? credential = null)
{
    public string RepositoryPath { get; } = repositoryPath;
    public GitEnvironment Git { get; } = git;
    public GitCredential? Credential { get; } = credential;

    const string TokenEnv = "GITCLOUD_SYNC_TOKEN";
    const string UserEnv = "GITCLOUD_SYNC_USER";

    /// <summary>
    /// <c>-c</c> options prepended to every command. With an app-owned token, the github.com
    /// credential helpers are replaced by an inline one that reads the token from the environment,
    /// so the token never appears in the command line or on disk.
    /// </summary>
    public IReadOnlyList<string> ConfigArguments
    {
        get
        {
            var args = new List<string> { "-c", "core.quotepath=false", "-c", "color.ui=never", "-c", "advice.detachedHead=false",
                                          "-c", "core.longpaths=true" };
            if (Credential != null)
            {
                var helper = $"!f() {{ if [ \"$1\" = get ]; then printf 'username=%s\\npassword=%s\\n' \"${UserEnv}\" \"${TokenEnv}\"; fi; }}; f";
                args.AddRange(["-c", "credential.https://github.com.helper=", "-c", $"credential.https://github.com.helper={helper}"]);
            }
            return args;
        }
    }

    public IReadOnlyDictionary<string, string> Environment
    {
        get
        {
            // Read on every command so turning the proxy on or off takes effect at the next sync.
            var env = SystemProxy.Applying(Git.Environment);
            if (Credential != null)
            {
                env[TokenEnv] = Credential.Token;
                env[UserEnv] = Credential.Username;
            }
            return env;
        }
    }

    public Task<ProcessResult> RunAsync(IReadOnlyList<string> arguments, TimeSpan? timeout = null, byte[]? stdin = null,
                                        IReadOnlyList<string>? extraConfig = null, CancellationToken cancellationToken = default) =>
        ProcessRunner.RunAsync(Git.GitPath, [.. ConfigArguments, .. extraConfig ?? [], .. arguments], RepositoryPath,
                               Environment, stdin, timeout ?? TimeSpan.FromSeconds(60), cancellationToken);
}
