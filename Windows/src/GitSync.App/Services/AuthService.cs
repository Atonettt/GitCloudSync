using System.Text;
using GitSync.Core;

namespace GitSync.App.Services;

public enum AuthSource { PersonalToken, GitHubCli, CredentialManager }

public abstract record AuthState
{
    public sealed record Unknown : AuthState;
    public sealed record Checking : AuthState;
    public sealed record SignedIn(string Login, AuthSource Source) : AuthState;
    /// <summary>A credential exists but GitHub couldn't be asked (offline).</summary>
    public sealed record Unverified(AuthSource Source, string Detail) : AuthState;
    public sealed record SignedOut : AuthState;
    public sealed record Invalid(AuthSource Source, string Message) : AuthState;

    public bool IsUsable => this is SignedIn or Unverified;

    public static string SourceName(AuthSource source) => source switch
    {
        AuthSource.PersonalToken => L.T("个人访问令牌", "personal access token"),
        AuthSource.GitHubCli => "GitHub CLI",
        _ => L.T("Git 凭据管理器", "Git Credential Manager"),
    };

    public string Summary => this switch
    {
        SignedIn s => L.T($"已登录 {s.Login}（{SourceName(s.Source)}）", $"Signed in as {s.Login} ({SourceName(s.Source)})"),
        Unverified u => L.T($"已找到凭据（{SourceName(u.Source)}），暂时无法验证", $"Credentials found ({SourceName(u.Source)}), can't verify right now"),
        SignedOut => L.T("未登录 GitHub", "Not signed in to GitHub"),
        Invalid i => i.Message,
        Checking => L.T("正在检测 GitHub 登录状态…", "Checking GitHub sign-in…"),
        _ => L.T("尚未检测", "Not checked yet"),
    };
}

/// <summary>
/// Finds a GitHub token, in order: one saved in GitSync, GitHub CLI, Git Credential Manager
/// (installed with Git for Windows). "Sign in with browser" goes through Git Credential Manager.
/// </summary>
public sealed class AuthService
{
    public AuthState State { get; private set; } = new AuthState.Unknown();
    public GitHubUser? User { get; private set; }
    public event Action? Changed;

    string? token;
    AuthSource source;

    public GitIdentity? Identity => User is { } user ? new GitIdentity(user.Name ?? user.Login, user.NoreplyEmail) : null;

    public async Task RefreshAsync(GitEnvironment? git)
    {
        State = new AuthState.Checking();
        Changed?.Invoke();
        var found = await FindToken(git);
        if (found is not { } candidate)
        {
            token = null;
            User = null;
            State = new AuthState.SignedOut();
            Changed?.Invoke();
            return;
        }
        (token, source) = candidate;
        try
        {
            User = await GitHubApi.FetchUserAsync(token);
            State = new AuthState.SignedIn(User.Login, source);
        }
        catch (GitHubApiException error) when (error.IsNetwork)
        {
            State = new AuthState.Unverified(source, error.Message);
        }
        catch (GitHubApiException error)
        {
            State = new AuthState.Invalid(source, L.T($"GitHub 凭据无效（{AuthState.SourceName(source)}）：{error.Message}",
                                                      $"The GitHub credentials are invalid ({AuthState.SourceName(source)}): {error.Message}"));
            token = null;
        }
        Changed?.Invoke();
    }

    public async Task<GitCredential?> CredentialForGitAsync(GitEnvironment? git)
    {
        if (token == null && State is AuthState.Unknown) await RefreshAsync(git);
        return token == null ? null : new GitCredential(token);
    }

    public string? Token => token;

    /// <summary>Saves a personal access token after checking it with GitHub.</summary>
    public async Task<string?> SignInWithTokenAsync(string value, GitEnvironment? git)
    {
        value = value.Trim();
        try
        {
            await GitHubApi.FetchUserAsync(value);
        }
        catch (Exception error)
        {
            return error.Message;
        }
        CredentialStore.SaveToken(value);
        await RefreshAsync(git);
        return null;
    }

    /// <summary>
    /// Opens Git Credential Manager's own sign-in window (browser or device code). The token it
    /// returns is stored by GCM, where GitSync finds it from now on.
    /// </summary>
    public async Task<string?> SignInWithBrowserAsync(GitEnvironment git)
    {
        var env = new Dictionary<string, string>(git.Environment) { ["GCM_INTERACTIVE"] = "always", ["GIT_TERMINAL_PROMPT"] = "0" };
        var input = Encoding.UTF8.GetBytes("protocol=https\nhost=github.com\n\n");
        var fill = await ProcessRunner.RunAsync(git.GitPath, ["credential", "fill"], environment: env, stdin: input, timeout: TimeSpan.FromMinutes(10));
        if (!fill.Succeeded || !fill.Stdout.Contains("password="))
            return L.T("没有完成登录。请确认已安装 Git for Windows（自带 Git 凭据管理器）。", "Sign-in didn't finish. Make sure Git for Windows (with Git Credential Manager) is installed.")
                   + (fill.Stderr.Trim().Length > 0 ? "\n\n" + fill.Stderr.Trim() : "");
        await ProcessRunner.RunAsync(git.GitPath, ["credential", "approve"], environment: env, stdin: fill.StdoutData, timeout: TimeSpan.FromSeconds(30));
        await RefreshAsync(git);
        return State.IsUsable ? null : State.Summary;
    }

    public async Task SignOutAsync(GitEnvironment? git)
    {
        CredentialStore.DeleteToken();
        await RefreshAsync(git);
    }

    /// <summary>Called when git reports an authentication failure: forget the cached token.</summary>
    public void HandleGitAuthFailure()
    {
        token = null;
        State = new AuthState.Unknown();
        Changed?.Invoke();
    }

    static async Task<(string Token, AuthSource Source)?> FindToken(GitEnvironment? git)
    {
        if (CredentialStore.ReadToken() is { Length: > 0 } saved) return (saved, AuthSource.PersonalToken);

        if (GitEnvironment.FindExecutable("gh") is { } gh)
        {
            try
            {
                var result = await ProcessRunner.RunAsync(gh, ["auth", "token", "--hostname", "github.com"],
                                                          environment: GitEnvironment.BuildEnvironment(), timeout: TimeSpan.FromSeconds(15));
                if (result.Succeeded && result.Stdout.Trim() is { Length: > 0 } value) return (value, AuthSource.GitHubCli);
            }
            catch { /* gh not usable */ }
        }

        if (git != null)
        {
            try
            {
                var input = Encoding.UTF8.GetBytes("protocol=https\nhost=github.com\n\n");
                var result = await ProcessRunner.RunAsync(git.GitPath, ["credential", "fill"], environment: git.Environment, stdin: input,
                                                          timeout: TimeSpan.FromSeconds(15));
                var password = result.Stdout.Split('\n').FirstOrDefault(l => l.StartsWith("password="))?["password=".Length..].Trim();
                if (result.Succeeded && !string.IsNullOrEmpty(password)) return (password, AuthSource.CredentialManager);
            }
            catch { /* no credential helper */ }
        }
        return null;
    }
}
