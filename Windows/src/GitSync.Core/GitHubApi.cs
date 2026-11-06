using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace GitSync.Core;

public sealed record GitHubUser(
    [property: JsonPropertyName("login")] string Login,
    [property: JsonPropertyName("id")] long Id,
    [property: JsonPropertyName("name")] string? Name)
{
    public string NoreplyEmail => $"{Id}+{Login}@users.noreply.github.com";
}

public sealed record CreatedRepository(
    [property: JsonPropertyName("full_name")] string FullName,
    [property: JsonPropertyName("clone_url")] string CloneUrl,
    [property: JsonPropertyName("html_url")] string HtmlUrl);

/// <summary>One repository in the signed-in account's list.</summary>
public sealed record GitHubRepositorySummary(
    [property: JsonPropertyName("id")] long Id,
    [property: JsonPropertyName("name")] string Name,
    [property: JsonPropertyName("full_name")] string FullName,
    [property: JsonPropertyName("private")] bool IsPrivate,
    [property: JsonPropertyName("clone_url")] string CloneUrl,
    [property: JsonPropertyName("html_url")] string HtmlUrl,
    [property: JsonPropertyName("description")] string? Description,
    [property: JsonPropertyName("pushed_at")] DateTimeOffset? PushedAt,
    [property: JsonPropertyName("size")] long Size,
    [property: JsonPropertyName("archived")] bool IsArchived);

[JsonSerializable(typeof(GitHubUser))]
[JsonSerializable(typeof(CreatedRepository))]
[JsonSerializable(typeof(List<GitHubRepositorySummary>))]
[JsonSerializable(typeof(Dictionary<string, object>))]
[JsonSerializable(typeof(Dictionary<string, string>))]
[JsonSerializable(typeof(Dictionary<string, bool>))]
internal sealed partial class GitHubJson : JsonSerializerContext;

public enum GitHubErrorKind { Unauthorized, NameTaken, MissingDeleteScope, NotFound, CannotCreate, Http, Network }

public sealed class GitHubApiException(GitHubErrorKind kind, string detail = "") : Exception(Describe(kind, detail))
{
    public GitHubErrorKind Kind { get; } = kind;
    public bool IsNetwork => Kind == GitHubErrorKind.Network;

    static string Describe(GitHubErrorKind kind, string detail) => kind switch
    {
        GitHubErrorKind.Unauthorized => L.T("令牌无效或已过期（HTTP 401）", "The token is invalid or expired (HTTP 401)"),
        GitHubErrorKind.NameTaken => L.T("你的 GitHub 账号下已经有同名仓库", "Your GitHub account already has a repository with this name"),
        GitHubErrorKind.MissingDeleteScope => L.T("当前登录的令牌没有删除仓库的权限（delete_repo）", "The signed-in token can't delete repositories (delete_repo)"),
        GitHubErrorKind.NotFound => L.T("GitHub 上找不到这个仓库", "The repository wasn't found on GitHub"),
        GitHubErrorKind.CannotCreate => L.T($"当前登录的令牌没有创建仓库的权限（{detail}）。请用 GitHub CLI 登录，或使用带 repo 权限的经典令牌。",
                                            $"The signed-in token can't create repositories ({detail}). Sign in with GitHub CLI, or use a classic token with the repo scope."),
        GitHubErrorKind.Http => L.T($"GitHub 返回 {detail}", $"GitHub returned {detail}"),
        _ => L.T($"无法连接 GitHub：{detail}", $"Can't reach GitHub: {detail}"),
    };
}

/// <summary>Minimal GitHub REST client. Uses the system proxy like the browser does.</summary>
public static class GitHubApi
{
    static readonly HttpClient Http = new(new SocketsHttpHandler
    {
        // The Windows (or macOS) proxy setting, picked up automatically.
        UseProxy = true,
        AutomaticDecompression = DecompressionMethods.All,
    })
    {
        BaseAddress = new Uri("https://api.github.com/"),
        Timeout = TimeSpan.FromSeconds(30),
    };

    public static async Task<GitHubUser> FetchUserAsync(string token)
    {
        var (status, body) = await Send(HttpMethod.Get, "user", token);
        return status switch
        {
            HttpStatusCode.OK => JsonSerializer.Deserialize(body, GitHubJson.Default.GitHubUser)!,
            HttpStatusCode.Unauthorized => throw new GitHubApiException(GitHubErrorKind.Unauthorized),
            _ => throw Unexpected(status, body),
        };
    }

    /// <summary>Creates a repository under the signed-in account.</summary>
    public static async Task<CreatedRepository> CreateRepositoryAsync(string token, string name, bool isPrivate, string description)
    {
        var json = $"{{\"name\":{JsonString(name)},\"private\":{(isPrivate ? "true" : "false")},\"auto_init\":false" +
                   (description.Length > 0 ? $",\"description\":{JsonString(description)}" : "") + "}";
        var (status, body) = await Send(HttpMethod.Post, "user/repos", token, json);
        return status switch
        {
            HttpStatusCode.Created => JsonSerializer.Deserialize(body, GitHubJson.Default.CreatedRepository)!,
            HttpStatusCode.Unauthorized => throw new GitHubApiException(GitHubErrorKind.Unauthorized),
            HttpStatusCode.UnprocessableEntity when body.Contains("already exists") => throw new GitHubApiException(GitHubErrorKind.NameTaken),
            HttpStatusCode.Forbidden or HttpStatusCode.NotFound => throw new GitHubApiException(GitHubErrorKind.CannotCreate, $"HTTP {(int)status}"),
            _ => throw Unexpected(status, body),
        };
    }

    public static async Task<CreatedRepository> RenameRepositoryAsync(string token, string owner, string name, string newName)
    {
        var (status, body) = await Send(HttpMethod.Patch, RepoPath(owner, name), token, $"{{\"name\":{JsonString(newName)}}}");
        return status switch
        {
            HttpStatusCode.OK => JsonSerializer.Deserialize(body, GitHubJson.Default.CreatedRepository)!,
            HttpStatusCode.Unauthorized => throw new GitHubApiException(GitHubErrorKind.Unauthorized),
            HttpStatusCode.NotFound => throw new GitHubApiException(GitHubErrorKind.NotFound),
            HttpStatusCode.UnprocessableEntity when body.Contains("already exists") => throw new GitHubApiException(GitHubErrorKind.NameTaken),
            _ => throw Unexpected(status, body),
        };
    }

    /// <summary>The repository as GitHub knows it now; for a renamed repository GitHub redirects to it.</summary>
    public static async Task<CreatedRepository> RepositoryAsync(string token, string owner, string name)
    {
        var (status, body) = await Send(HttpMethod.Get, RepoPath(owner, name), token);
        return status switch
        {
            HttpStatusCode.OK => JsonSerializer.Deserialize(body, GitHubJson.Default.CreatedRepository)!,
            HttpStatusCode.Unauthorized => throw new GitHubApiException(GitHubErrorKind.Unauthorized),
            HttpStatusCode.NotFound => throw new GitHubApiException(GitHubErrorKind.NotFound),
            _ => throw Unexpected(status, body),
        };
    }

    /// <summary>Permanently deletes a repository. Needs the delete_repo scope.</summary>
    public static async Task DeleteRepositoryAsync(string token, string owner, string name)
    {
        var (status, body) = await Send(HttpMethod.Delete, RepoPath(owner, name), token);
        switch (status)
        {
            case HttpStatusCode.NoContent: return;
            case HttpStatusCode.Unauthorized: throw new GitHubApiException(GitHubErrorKind.Unauthorized);
            case HttpStatusCode.Forbidden: throw new GitHubApiException(GitHubErrorKind.MissingDeleteScope);
            case HttpStatusCode.NotFound: throw new GitHubApiException(GitHubErrorKind.NotFound);
            default: throw Unexpected(status, body);
        }
    }

    /// <summary>Repositories the account owns or collaborates on, most recently pushed first.</summary>
    public static async Task<List<GitHubRepositorySummary>> ListRepositoriesAsync(string token, int maxPages = 10)
    {
        var all = new List<GitHubRepositorySummary>();
        for (var page = 1; page <= maxPages; page++)
        {
            var (status, body) = await Send(HttpMethod.Get, $"user/repos?per_page=100&page={page}&sort=pushed&affiliation=owner,collaborator", token);
            if (status == HttpStatusCode.Unauthorized) throw new GitHubApiException(GitHubErrorKind.Unauthorized);
            if (status != HttpStatusCode.OK) throw Unexpected(status, body);
            var batch = JsonSerializer.Deserialize(body, GitHubJson.Default.ListGitHubRepositorySummary) ?? [];
            all.AddRange(batch);
            if (batch.Count < 100) break;
        }
        return all;
    }

    static string RepoPath(string owner, string name) => $"repos/{Uri.EscapeDataString(owner)}/{Uri.EscapeDataString(name)}";

    static string JsonString(string value) => JsonSerializer.Serialize(value, GitHubJson.Default.String);

    static GitHubApiException Unexpected(HttpStatusCode status, string body) =>
        new(GitHubErrorKind.Http, $"HTTP {(int)status}: {(body.Length > 300 ? body[..300] : body)}");

    static async Task<(HttpStatusCode Status, string Body)> Send(HttpMethod method, string path, string token, string? json = null)
    {
        using var request = new HttpRequestMessage(method, path);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        request.Headers.Accept.ParseAdd("application/vnd.github+json");
        request.Headers.Add("X-GitHub-Api-Version", "2022-11-28");
        request.Headers.UserAgent.ParseAdd("GitSync");
        if (json != null) request.Content = new StringContent(json, Encoding.UTF8, "application/json");
        try
        {
            using var response = await Http.SendAsync(request);
            return (response.StatusCode, await response.Content.ReadAsStringAsync());
        }
        catch (Exception error) when (error is HttpRequestException or TaskCanceledException)
        {
            throw new GitHubApiException(GitHubErrorKind.Network, error.Message);
        }
    }
}
