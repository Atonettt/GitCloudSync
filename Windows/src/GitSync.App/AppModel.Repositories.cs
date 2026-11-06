using GitSync.App.Services;
using GitSync.Core;

namespace GitSync.App;

public abstract record CreationOutcome
{
    public sealed record Created : CreationOutcome;
    public sealed record Failed(string Message) : CreationOutcome;
    /// <summary>The name is taken by an empty repository of the same account, which can be linked instead.</summary>
    public sealed record NameTakenButEmpty(string FullName) : CreationOutcome;
}

public abstract record DeletionOutcome
{
    public sealed record Done : DeletionOutcome;
    public sealed record Failed(string Message) : DeletionOutcome;
    /// <summary>GitHub refused: the token lacks the delete_repo permission.</summary>
    public sealed record NeedsDeleteScope : DeletionOutcome;
}

public sealed partial class AppModel
{
    // MARK: Adding repositories

    /// <summary>
    /// Adds folders to the list. Folders already linked to GitHub are added right away; plain folders
    /// (and repositories without a remote) are returned so the window can offer to create a GitHub repository.
    /// </summary>
    public async Task<(List<string> NeedCreation, List<string> Problems)> AddRepositoriesAsync(IEnumerable<string> folders)
    {
        var needCreation = new List<string>();
        var problems = new List<string>();
        if (Git is not { } git)
        {
            problems.Add(GitProblem ?? L.T("未找到 Git", "Git wasn't found"));
            return (needCreation, problems);
        }
        foreach (var folder in folders)
        {
            if (RepositoryCreator.RefusalReason(folder) is { } reason) { problems.Add(reason); continue; }
            try
            {
                var info = await new RepositoryInspector(new GitClient(folder, git)).InspectAsync();
                var top = RepositoryCreator.Canonical(info.TopLevelPath);
                if (info.RemoteUrl == null && string.Equals(top, RepositoryCreator.Canonical(folder), StringComparison.OrdinalIgnoreCase))
                {
                    needCreation.Add(folder);
                    continue;
                }
                if (Repositories.Any(r => string.Equals(RepositoryCreator.Canonical(r.Path), top, StringComparison.OrdinalIgnoreCase)))
                {
                    problems.Add(L.T($"「{Path.GetFileName(folder)}」已经在列表中。", $"“{Path.GetFileName(folder)}” is already in the list."));
                    continue;
                }
                var config = new RepositoryConfig
                {
                    Path = info.TopLevelPath,
                    DisplayName = Path.GetFileName(info.TopLevelPath.TrimEnd('\\', '/')),
                    KnownRemote = info.RemoteUrl,
                    FileId = FolderLocator.FileId(info.TopLevelPath),
                };
                Repositories.Add(config);
                State(config.Id).Info = info;
                Log(config.Id, L.T("添加仓库", "Add repository"), LogLevel.Success, L.T($"已添加仓库 {config.DisplayName}", $"Added {config.DisplayName}"),
                    detail: L.T($"路径：{info.TopLevelPath}\n分支：{info.Branch ?? "-"}\n远程：{info.RemoteUrl ?? "-"}",
                                $"Path: {info.TopLevelPath}\nBranch: {info.Branch ?? "-"}\nRemote: {info.RemoteUrl ?? "-"}"));
                if (!string.Equals(top, RepositoryCreator.Canonical(folder), StringComparison.OrdinalIgnoreCase))
                    problems.Add(L.T($"「{Path.GetFileName(folder)}」位于仓库内部，已改为添加仓库根目录：{info.TopLevelPath}",
                                     $"“{Path.GetFileName(folder)}” is inside a repository; added its top folder instead: {info.TopLevelPath}"));
                if (info.InProgressOperation is { } op)
                    problems.Add(L.T($"「{config.DisplayName}」有未完成的{op.DisplayName()}，需要先处理才能同步。",
                                     $"“{config.DisplayName}” has an unfinished {op.DisplayName()} to deal with first."));
                Sync(config.Id, SyncTrigger.ManualSingle);
                _ = RefreshUsageAsync(config.Id, force: true);
            }
            catch (SyncFailure failure) when (failure.Kind == FailureKind.NotARepository)
            {
                needCreation.Add(folder);
            }
            catch (SyncFailure failure)
            {
                problems.Add($"「{Path.GetFileName(folder)}」：{failure.Explanation}\n{failure.Suggestion}");
            }
        }
        Persist();
        Notify(null);
        return (needCreation, problems);
    }

    public Task<FolderPreview?> PreviewFolderAsync(string folder) =>
        Git is { } git
            ? new RepositoryCreator(git).PreviewAsync(folder, (long)Math.Max(1, Settings.LargeFileLimitMB) * 1024 * 1024, Settings.IgnorePatterns)!
            : Task.FromResult<FolderPreview?>(null);

    /// <summary>Creates the GitHub repository (or links an empty one), prepares the folder and syncs it.</summary>
    public async Task<CreationOutcome> CreateGitHubRepositoryAsync(string folder, string name, bool isPrivate, string description, bool linkExisting)
    {
        if (Git is not { } git) return new CreationOutcome.Failed(GitProblem ?? L.T("未找到 Git", "Git wasn't found"));
        if (await Auth.CredentialForGitAsync(git) is not { } credential)
            return new CreationOutcome.Failed(L.T("需要先在「设置 › GitHub 账户」中登录 GitHub。", "Sign in to GitHub in Settings › GitHub Account first."));
        var creator = new RepositoryCreator(git);
        var login = Auth.User?.Login;
        string remoteUrl;
        try
        {
            if (linkExisting)
            {
                if (login == null) return new CreationOutcome.Failed(L.T("无法确定当前 GitHub 账号，请在设置中重新检测登录状态。", "The GitHub account is unknown; check the sign-in in Settings."));
                remoteUrl = $"https://github.com/{login}/{name}.git";
                if (!await creator.RemoteIsEmptyAsync(remoteUrl, credential, folder))
                    return new CreationOutcome.Failed(L.T($"GitHub 上的「{login}/{name}」已有内容，不能直接关联。请换一个仓库名。", $"“{login}/{name}” on GitHub isn't empty; choose another name."));
            }
            else
            {
                try
                {
                    var created = await GitHubApi.CreateRepositoryAsync(credential.Token, name, isPrivate, description);
                    remoteUrl = created.CloneUrl;
                    Log(null, L.T("创建仓库", "Create repository"), LogLevel.Success,
                        isPrivate ? L.T($"已在 GitHub 创建私有仓库 {created.FullName}", $"Created the private repository {created.FullName}")
                                  : L.T($"已在 GitHub 创建公开仓库 {created.FullName}", $"Created the public repository {created.FullName}"),
                        detail: $"{folder}\n{created.HtmlUrl}");
                }
                catch (GitHubApiException error) when (error.Kind == GitHubErrorKind.NameTaken)
                {
                    if (login != null && await creator.RemoteIsEmptyAsync($"https://github.com/{login}/{name}.git", credential, folder))
                        return new CreationOutcome.NameTakenButEmpty($"{login}/{name}");
                    return new CreationOutcome.Failed(L.T($"你的 GitHub 账号下已经有名为「{name}」的仓库，请换一个名字。", $"Your account already has a repository named “{name}”; choose another name."));
                }
            }
            await creator.PrepareAsync(folder, remoteUrl, Auth.Identity, Settings.IgnorePatterns);
        }
        catch (GitHubApiException error) { return new CreationOutcome.Failed(error.Message); }
        catch (SyncFailure failure) { return new CreationOutcome.Failed(failure.Explanation + (failure.Stderr.Length > 0 ? "\n\n" + failure.Stderr : "")); }
        catch (Exception error) { return new CreationOutcome.Failed(error.Message); }

        var path = RepositoryCreator.Canonical(folder);
        if (Repositories.FirstOrDefault(r => string.Equals(RepositoryCreator.Canonical(r.Path), path, StringComparison.OrdinalIgnoreCase)) is { } existing)
        {
            existing.AutoSyncEnabled = true;
            existing.LastMessage = null;
            await RefreshInfoAsync(existing.Id);
            Sync(existing.Id, SyncTrigger.ManualSingle);
        }
        else
        {
            await AddRepositoriesAsync([folder]);
        }
        return new CreationOutcome.Created();
    }

    // MARK: Removing and deleting

    public void RemoveRepository(Guid id)
    {
        if (Repository(id) is not { } repo) return;
        Repositories.Remove(repo);
        Runtime.Remove(id);
        Persist();
        Log(null, L.T("移除仓库", "Remove"), LogLevel.Info, L.T($"已从列表移除 {repo.DisplayName}（文件夹和 GitHub 仓库都保留）", $"Removed {repo.DisplayName} from the list (folder and GitHub repository kept)"));
        Notify(null);
    }

    public void MoveRepository(Guid id, int newIndex)
    {
        if (Repository(id) is not { } repo) return;
        Repositories.Remove(repo);
        Repositories.Insert(Math.Clamp(newIndex, 0, Repositories.Count), repo);
        Persist();
        Notify(null);
    }

    public async Task<DeletionCheck?> DeletionCheckAsync(Guid id, bool fetch)
    {
        if (Git is not { } git || Repository(id) is not { } repo || !Directory.Exists(repo.Path)) return null;
        try { return await new RepositoryRemoval(new GitClient(repo.Path, git, await Auth.CredentialForGitAsync(git))).CheckAsync(fetch); }
        catch { return null; }
    }

    /// <summary>Deletes the GitHub repository, the local folder (to the Recycle Bin), or both.</summary>
    public async Task<DeletionOutcome> DeleteRepositoryAsync(Guid id, bool deleteOnGitHub, bool deleteLocal)
    {
        if (Repository(id) is not { } repo) return new DeletionOutcome.Failed(L.T("仓库不存在", "The repository is gone"));
        var git = Git;
        if (deleteOnGitHub)
        {
            var remote = State(id).Info?.RemoteUrl ?? repo.KnownRemote;
            if (remote == null || RepositoryRemoval.GitHubFullName(remote) is not { } target)
                return new DeletionOutcome.Failed(L.T("这个仓库没有 GitHub 远程地址", "This repository has no GitHub remote"));
            if (await Auth.CredentialForGitAsync(git) is not { } credential) return new DeletionOutcome.Failed(L.T("未登录 GitHub", "Not signed in to GitHub"));
            try
            {
                await GitHubApi.DeleteRepositoryAsync(credential.Token, target.Owner, target.Name);
                Log(id, L.T("删除 GitHub 仓库", "Delete GitHub repository"), LogLevel.Warning,
                    L.T($"已删除 GitHub 上的仓库 {target.Owner}/{target.Name}", $"Deleted {target.Owner}/{target.Name} on GitHub"));
            }
            catch (GitHubApiException error) when (error.Kind == GitHubErrorKind.MissingDeleteScope) { return new DeletionOutcome.NeedsDeleteScope(); }
            catch (GitHubApiException error) when (error.Kind == GitHubErrorKind.NotFound) { }
            catch (Exception error) { return new DeletionOutcome.Failed(error.Message); }

            if (!deleteLocal && git != null)
            {
                try
                {
                    var name = await new RepositoryRemoval(new GitClient(repo.Path, git)).DetachDeletedRemoteAsync();
                    repo.AutoSyncEnabled = false;
                    repo.LastMessage = L.T("GitHub 上的仓库已删除，本地文件夹保留", "Deleted on GitHub; the folder is kept");
                    Log(id, L.T("删除 GitHub 仓库", "Delete GitHub repository"), LogLevel.Info,
                        L.T($"本地仓库已与 GitHub 断开（原 origin 改名为 {name}），可在「更多」中重新发布", $"The folder is now local-only (origin renamed to {name}); publish it again from More"));
                    await RefreshInfoAsync(id);
                }
                catch (Exception error) { return new DeletionOutcome.Failed(error.Message); }
            }
        }
        if (deleteLocal)
        {
            try
            {
                if (Directory.Exists(repo.Path)) Shell.MoveToRecycleBin(repo.Path);
                Log(null, L.T("删除本地文件夹", "Delete folder"), LogLevel.Warning, L.T($"已将 {repo.Path} 移到回收站", $"Moved {repo.Path} to the Recycle Bin"));
            }
            catch (Exception error) { return new DeletionOutcome.Failed(error.Message); }
            RemoveRepository(id);
        }
        Persist();
        Notify(null);
        return new DeletionOutcome.Done();
    }

    // MARK: Moved and deleted folders

    /// <summary>Follows a folder that was moved or renamed. False when it can't be used where it is.</summary>
    public bool FollowFolder(Guid id)
    {
        if (Repository(id) is not { } repo) return false;
        var state = State(id);
        switch (FolderLocator.Locate(repo.Path, repo.FileId))
        {
            case FolderLocator.Location.Unchanged:
                state.RecycledPath = null;
                return true;
            case FolderLocator.Location.Moved moved:
                var renamed = !string.Equals(Path.GetFileName(moved.Path), Path.GetFileName(repo.Path), StringComparison.OrdinalIgnoreCase);
                Adopt(id, moved.Path, L.T($"{repo.DisplayName} 已移动到 {moved.Path}，继续同步", $"{repo.DisplayName} moved to {moved.Path}; still syncing"));
                if (renamed) _ = RenameRemoteToMatchFolderAsync(id);
                return true;
            case FolderLocator.Location.InRecycleBin recycled:
                state.RecycledPath = recycled.Path;
                return false;
            default:
                state.RecycledPath = null;
                return false;
        }
    }

    void Adopt(Guid id, string folder, string message)
    {
        if (Repository(id) is not { } repo) return;
        var oldName = Path.GetFileName(repo.Path.TrimEnd('\\', '/'));
        repo.Path = folder;
        repo.FileId = FolderLocator.FileId(folder);
        if (repo.DisplayName == oldName) repo.DisplayName = Path.GetFileName(folder.TrimEnd('\\', '/'));
        if (repo.LastFailure?.Kind == FailureKind.FolderMissing)
        {
            repo.LastFailure = null;
            repo.LastStatus = SyncStatus.NotSynced;
            repo.LastMessage = null;
        }
        State(id).RecycledPath = null;
        Persist();
        Log(id, L.T("文件夹位置", "Folder location"), LogLevel.Info, message);
        _ = RefreshUsageAsync(id, force: true);
        Notify(id);
    }

    /// <summary>Uses a folder as the repository's new place after checking it is the same repository.</summary>
    public async Task<string?> RelocateAsync(Guid id, string folder)
    {
        if (Repository(id) is not { } repo || Git is not { } git) return GitProblem;
        var path = RepositoryCreator.Canonical(folder);
        if (Repositories.FirstOrDefault(r => r.Id != id && string.Equals(RepositoryCreator.Canonical(r.Path), path, StringComparison.OrdinalIgnoreCase)) is { } other)
            return L.T($"「{Path.GetFileName(folder)}」已经是列表中的「{other.DisplayName}」。", $"“{Path.GetFileName(folder)}” is already “{other.DisplayName}” in the list.");
        var client = new GitClient(folder, git);
        var remote = await client.RunAsync(["remote", "get-url", "origin"], TimeSpan.FromSeconds(15));
        var sameRemote = remote.Succeeded && repo.KnownRemote != null && SameRemote(remote.Stdout.Trim(), repo.KnownRemote);
        var sameHistory = repo.KnownCommit != null && (await client.RunAsync(["cat-file", "-e", repo.KnownCommit + "^{commit}"], TimeSpan.FromSeconds(15))).Succeeded;
        if (!sameRemote && !sameHistory)
            return L.T($"「{Path.GetFileName(folder)}」不是「{repo.DisplayName}」这个仓库：远程地址和提交记录都对不上。",
                       $"“{Path.GetFileName(folder)}” isn't “{repo.DisplayName}”: neither the remote nor the history match.");
        Adopt(id, folder, L.T($"{repo.DisplayName} 已重新定位到 {folder}", $"{repo.DisplayName} now points to {folder}"));
        await RefreshInfoAsync(id);
        return null;
    }

    static bool SameRemote(string a, string b) =>
        RepositoryRemoval.GitHubFullName(a) is { } x && RepositoryRemoval.GitHubFullName(b) is { } y
            ? string.Equals($"{x.Owner}/{x.Name}", $"{y.Owner}/{y.Name}", StringComparison.OrdinalIgnoreCase)
            : string.Equals(a.Trim(), b.Trim(), StringComparison.OrdinalIgnoreCase);

    /// <summary>Moves a recycled repository folder back to where it was.</summary>
    public async Task PutBackFromRecycleBinAsync(Guid id)
    {
        if (Repository(id) is not { } repo || State(id).RecycledPath is not { } recycled) return;
        try
        {
            if (Directory.Exists(repo.Path)) throw new IOException(L.T($"{repo.Path} 已存在", $"{repo.Path} already exists"));
            Directory.CreateDirectory(Path.GetDirectoryName(repo.Path)!);
            Directory.Move(recycled, repo.Path);
            Adopt(id, repo.Path, L.T($"已将 {repo.DisplayName} 从回收站放回 {repo.Path}", $"Put {repo.DisplayName} back from the Recycle Bin"));
            await RefreshInfoAsync(id);
        }
        catch (Exception error)
        {
            ShowAlert?.Invoke(L.T("无法放回原处", "Couldn't put it back"), error.Message);
        }
    }

    /// <summary>Downloads a repository whose folder was deleted from GitHub again, then keeps syncing.</summary>
    public async Task RedownloadAsync(Guid id, string? folder = null)
    {
        if (Repository(id) is not { } repo || Git is not { } git) return;
        if ((State(id).Info?.RemoteUrl ?? repo.KnownRemote) is not { } remote)
        {
            ShowAlert?.Invoke(L.T("无法重新下载", "Can't download again"), L.T($"不知道「{repo.DisplayName}」对应的 GitHub 地址。请用「重新定位」选择文件夹。", $"The GitHub address of “{repo.DisplayName}” is unknown. Use Locate to choose its folder."));
            return;
        }
        var destination = folder ?? repo.Path;
        State(id).Downloading = true;
        Notify(id);
        Log(id, L.T("重新下载", "Download again"), LogLevel.Info, L.T($"正在从 GitHub 下载 {repo.DisplayName} 到 {destination}", $"Downloading {repo.DisplayName} from GitHub to {destination}"));
        try
        {
            await new RepositoryCreator(git).DownloadAsync(remote, destination, await Auth.CredentialForGitAsync(git), Auth.Identity, Settings.IgnorePatterns);
            Adopt(id, destination, L.T($"已从 GitHub 重新下载 {repo.DisplayName} 到 {destination}", $"Downloaded {repo.DisplayName} again to {destination}"));
            await RefreshInfoAsync(id);
        }
        catch (Exception error)
        {
            var message = (error as SyncFailure)?.Explanation ?? error.Message;
            Log(id, L.T("重新下载", "Download again"), LogLevel.Error, message);
            ShowAlert?.Invoke(L.T("无法重新下载", "Can't download again"), message);
        }
        State(id).Downloading = false;
        Notify(id);
    }

    // MARK: GitHub follows folder renames

    /// <summary>After the folder was renamed, gives the GitHub repository the same name (pinyin for Chinese).</summary>
    public async Task RenameRemoteToMatchFolderAsync(Guid id)
    {
        if (!Settings.RenameRemoteWithFolder || Git is not { } git) return;
        while (State(id).IsSyncing) await Task.Delay(1000);
        if (Repository(id) is not { } repo || (State(id).Info?.RemoteUrl ?? repo.KnownRemote) is not { } remote ||
            RepositoryRemoval.GitHubFullName(remote) is not { } target) return;
        var newName = RepositoryNaming.SuggestedName(Path.GetFileName(repo.Path.TrimEnd('\\', '/')));
        if (newName.Length == 0 || string.Equals(newName, target.Name, StringComparison.OrdinalIgnoreCase)) return;
        if (await Auth.CredentialForGitAsync(git) is not { } credential)
        {
            Log(id, L.T("仓库改名", "Rename"), LogLevel.Warning, L.T($"未登录 GitHub，GitHub 上的仓库名保持为 {target.Name}", $"Not signed in; the GitHub name stays {target.Name}"));
            return;
        }
        try
        {
            var renamed = await GitHubApi.RenameRepositoryAsync(credential.Token, target.Owner, target.Name, newName);
            await PointOriginAsync(id, renamed.CloneUrl, git);
            Log(id, L.T("仓库改名", "Rename"), LogLevel.Success, L.T($"GitHub 上的仓库已改名为 {renamed.FullName}", $"Renamed on GitHub to {renamed.FullName}"));
        }
        catch (Exception error)
        {
            Log(id, L.T("仓库改名", "Rename"), LogLevel.Warning, L.T($"GitHub 上的仓库没有改名：{error.Message}", $"Not renamed on GitHub: {error.Message}"));
        }
    }

    readonly HashSet<Guid> checkedRemoteRename = [];

    /// <summary>Once per launch: if the repository was renamed on GitHub (or by the other computer), follow it.</summary>
    async Task FollowRemoteRenameAsync(Guid id)
    {
        if (!checkedRemoteRename.Add(id) || Git is not { } git || Repository(id) is not { } repo) return;
        if ((State(id).Info?.RemoteUrl ?? repo.KnownRemote) is not { } remote || RepositoryRemoval.GitHubFullName(remote) is not { } target) return;
        if (await Auth.CredentialForGitAsync(git) is not { } credential) return;
        try
        {
            var current = await GitHubApi.RepositoryAsync(credential.Token, target.Owner, target.Name);
            if (!string.Equals(current.FullName, $"{target.Owner}/{target.Name}", StringComparison.OrdinalIgnoreCase))
            {
                await PointOriginAsync(id, current.CloneUrl, git);
                Log(id, L.T("仓库改名", "Rename"), LogLevel.Info, L.T($"GitHub 上的仓库已改名为 {current.FullName}，已跟随", $"Following the new GitHub name {current.FullName}"));
            }
        }
        catch { /* checked again next launch */ }
    }

    async Task PointOriginAsync(Guid id, string url, GitEnvironment git)
    {
        if (Repository(id) is not { } repo) return;
        await new GitClient(repo.Path, git).RunAsync(["remote", "set-url", "origin", url], TimeSpan.FromSeconds(15));
        repo.KnownRemote = url;
        Persist();
        await RefreshInfoAsync(id);
    }

    // MARK: Repositories on GitHub

    public async Task<List<GitHubRepositorySummary>> GitHubRepositoriesAsync()
    {
        var credential = await Auth.CredentialForGitAsync(Git) ?? throw new GitHubApiException(GitHubErrorKind.Unauthorized);
        return await GitHubApi.ListRepositoriesAsync(credential.Token);
    }

    public RepositoryConfig? ExistingRepository(GitHubRepositorySummary repository) =>
        Repositories.FirstOrDefault(config => (State(config.Id).Info?.RemoteUrl ?? config.KnownRemote) is { } remote &&
                                              RepositoryRemoval.GitHubFullName(remote) is { } name &&
                                              string.Equals($"{name.Owner}/{name.Name}", repository.FullName, StringComparison.OrdinalIgnoreCase));

    public string DefaultDownloadFolder
    {
        get
        {
            if (Repositories.FirstOrDefault() is { } first && Path.GetDirectoryName(first.Path) is { } parent && Directory.Exists(parent)) return parent;
            return Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments);
        }
    }

    public async Task<string?> DownloadFromGitHubAsync(GitHubRepositorySummary repository, string destination, bool autoSync)
    {
        if (Git is not { } git) return GitProblem ?? L.T("未找到 Git", "Git wasn't found");
        if (RepositoryCreator.RefusalReason(destination) is { } reason) return reason;
        try
        {
            await new RepositoryCreator(git).DownloadAsync(repository.CloneUrl, destination, await Auth.CredentialForGitAsync(git), Auth.Identity, Settings.IgnorePatterns);
        }
        catch (Exception error)
        {
            return (error as SyncFailure)?.Explanation ?? error.Message;
        }
        await AddRepositoriesAsync([destination]);
        if (Repositories.FirstOrDefault(r => string.Equals(RepositoryCreator.Canonical(r.Path), RepositoryCreator.Canonical(destination), StringComparison.OrdinalIgnoreCase)) is { } added)
        {
            Log(added.Id, L.T("从 GitHub 下载", "Download from GitHub"), LogLevel.Success,
                L.T($"已从 GitHub 下载 {repository.FullName} 到 {destination}", $"Downloaded {repository.FullName} to {destination}"));
            SelectRequested?.Invoke(added.Id);
            if (!autoSync) SetAutoSync(added.Id, false);
        }
        return null;
    }

    /// <summary>Asks the window to select a repository.</summary>
    public event Action<Guid>? SelectRequested;

    public async Task<DeletionOutcome> DeleteGitHubRepositoryAsync(GitHubRepositorySummary repository)
    {
        if (ExistingRepository(repository) != null)
            return new DeletionOutcome.Failed(L.T("这个仓库在列表中，请在它的仓库页「更多」菜单里删除。", "This repository is in the list; delete it from More on its page."));
        var parts = repository.FullName.Split('/', 2);
        if (await Auth.CredentialForGitAsync(Git) is not { } credential) return new DeletionOutcome.Failed(L.T("未登录 GitHub", "Not signed in to GitHub"));
        try
        {
            await GitHubApi.DeleteRepositoryAsync(credential.Token, parts[0], parts[1]);
        }
        catch (GitHubApiException error) when (error.Kind == GitHubErrorKind.MissingDeleteScope) { return new DeletionOutcome.NeedsDeleteScope(); }
        catch (GitHubApiException error) when (error.Kind == GitHubErrorKind.NotFound) { }
        catch (Exception error) { return new DeletionOutcome.Failed(error.Message); }
        Log(null, L.T("删除 GitHub 仓库", "Delete GitHub repository"), LogLevel.Warning, L.T($"已删除 GitHub 上的仓库 {repository.FullName}", $"Deleted {repository.FullName} on GitHub"));
        return new DeletionOutcome.Done();
    }

    // MARK: Documents open in Office

    /// <summary>
    /// After a sync downloaded new versions, reopens documents open in Word, Excel or PowerPoint so
    /// they show the new content; documents with unsaved edits are only touched after asking.
    /// </summary>
    void RefreshOpenDocuments(Guid id, IReadOnlyList<string> relativePaths)
    {
        if (Repository(id) is not { } repo) return;
        var candidates = relativePaths
            .Select(p => Path.Combine(repo.Path, p.Replace('/', '\\')))
            .Where(p => OfficeDocuments.IsOfficeFile(p) && File.Exists(p) && OfficeDocuments.ProbablyOpen(p))
            .ToList();
        if (candidates.Count == 0) return;
        var stage = L.T("刷新打开的文档", "Open documents");
        var documents = OfficeDocuments.OpenDocuments(candidates);
        foreach (var document in documents.Where(d => d.Saved))
        {
            if (OfficeDocuments.Reopen(document) is { } problem)
                Log(id, stage, LogLevel.Warning, L.T($"无法在 {document.App.Name} 中刷新「{document.FileName}」：{problem}", $"Couldn't refresh “{document.FileName}” in {document.App.Name}: {problem}"));
            else
            {
                Log(id, stage, LogLevel.Success, L.T($"已在 {document.App.Name} 中刷新「{document.FileName}」", $"Refreshed “{document.FileName}” in {document.App.Name}"));
                Notifications.Post(L.T($"已在 {document.App.Name} 中刷新", $"Refreshed in {document.App.Name}"), document.FileName);
            }
        }
        foreach (var document in documents.Where(d => !d.Saved)) EditedDocumentFound?.Invoke(id, document);
    }

    /// <summary>A document with unsaved edits got a newer version; the window asks what to do.</summary>
    public event Action<Guid, OfficeDocuments.OpenDocument>? EditedDocumentFound;

    // MARK: Files

    public async Task<HashSet<string>> UnsyncedPathsAsync(Guid id) => (await PendingChangesAsync(id)).Select(e => e.Path).ToHashSet();

    public string? WebUrl(Guid id) => (State(id).Info?.WebUrl ?? (Repository(id)?.KnownRemote is { } remote ? RepositoryInfo.WebUrlFromRemote(remote) : null))?.ToString();
}
