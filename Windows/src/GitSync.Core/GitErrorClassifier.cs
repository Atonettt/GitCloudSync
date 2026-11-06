namespace GitSync.Core;

/// <summary>Turns git output into a failure kind plus explanations.</summary>
public static class GitErrorClassifier
{
    // Ordered: specific causes (401/403/5xx) come before the generic "unable to access" git prints with them.
    static readonly (FailureKind Kind, string[] Needles)[] Rules =
    [
        (FailureKind.LargeFile, ["exceeds github's file size limit", "gh001", "large files detected", "this exceeds github", "file size limit of 100"]),
        (FailureKind.RepositoryNotFound, ["repository not found", "error: 404"]),
        (FailureKind.Authentication, [
            "authentication failed", "could not read username", "could not read password", "terminal prompts disabled",
            "invalid username or password", "permission denied (publickey)", "the requested url returned error: 401",
            "the requested url returned error: 403", "bad credentials", "support for password authentication was removed",
            "permission to ", "denied to ", "host key verification failed", "write access to repository not granted",
        ]),
        (FailureKind.ServerUnavailable, [
            "the requested url returned error: 500", "the requested url returned error: 502",
            "the requested url returned error: 503", "the requested url returned error: 504", "internal server error",
            "service unavailable", "remote end hung up unexpectedly", "rpc failed", "unexpected disconnect",
        ]),
        (FailureKind.Network, [
            "could not resolve host", "failed to connect", "connection timed out", "network is unreachable",
            "couldn't connect to server", "connection refused", "no route to host", "operation timed out",
            "ssl_error_syscall", "connection reset by peer", "could not resolve hostname", "unable to access",
            "temporary failure in name resolution", "nodename nor servname provided", "schannel",
        ]),
        (FailureKind.IndexLocked, ["index.lock", "another git process seems to be running"]),
        // Windows: a program (Word, Excel…) keeps the file open, so git can't replace it.
        (FailureKind.FileLocked, ["unable to unlink", "unable to create file", "deletion of directory", "invalid argument",
                                  "the process cannot access the file", "device or resource busy"]),
        (FailureKind.MissingIdentity, ["please tell me who you are", "unable to auto-detect email address"]),
        (FailureKind.UnrelatedHistories, ["refusing to merge unrelated histories"]),
        (FailureKind.MergeBlocked, [
            "would be overwritten by merge", "untracked working tree files would be",
            "your local changes to the following files would be overwritten", "not possible to fast-forward",
        ]),
        (FailureKind.PushRejected, ["[rejected]", "non-fast-forward", "fetch first", "failed to push some refs"]),
        (FailureKind.PermissionDenied, ["operation not permitted", "permission denied", "access is denied"]),
        (FailureKind.NotARepository, ["not a git repository"]),
        (FailureKind.NoRemote, ["'origin' does not appear to be a git repository", "no such remote"]),
    ];

    public static FailureKind Classify(string output, bool timedOut)
    {
        if (timedOut) return FailureKind.Timeout;
        var text = output.ToLowerInvariant();
        foreach (var (kind, needles) in Rules)
        {
            if (needles.Any(text.Contains)) return kind;
        }
        return FailureKind.Unknown;
    }

    public static string Message(FailureKind kind, SyncStage stage) => kind switch
    {
        FailureKind.Authentication => L.T($"GitHub 认证失败（{stage.DisplayName()}）", $"GitHub sign-in failed ({stage.DisplayName()})"),
        FailureKind.RepositoryNotFound => L.T("找不到 GitHub 仓库：可能已被删除或改名，或当前账号无权访问",
                                              "The GitHub repository wasn't found: it may have been deleted or renamed, or this account can't access it"),
        FailureKind.Network => L.T("无法连接 GitHub，网络不可用", "Can't reach GitHub; the network is unavailable"),
        FailureKind.ServerUnavailable => L.T("GitHub 服务器暂时不可用", "GitHub is temporarily unavailable"),
        FailureKind.Timeout => L.T($"Git 操作超时（{stage.DisplayName()}）", $"Git timed out ({stage.DisplayName()})"),
        FailureKind.FolderMissing => L.T("本地文件夹不存在或已被移动", "The folder is missing or was moved"),
        FailureKind.PermissionDenied => L.T("没有访问该文件夹的权限", "No permission to access the folder"),
        FailureKind.NotARepository => L.T("所选文件夹不是 Git 仓库", "The folder isn't a Git repository"),
        FailureKind.NoRemote => L.T("仓库没有配置远程 origin", "The repository has no origin remote"),
        FailureKind.DetachedHead => L.T("仓库处于分离 HEAD 状态，不在任何分支上", "The repository isn't on a branch (detached HEAD)"),
        FailureKind.UnbornWithRemote => L.T("本地仓库尚无提交，而远程分支已有内容", "Nothing is committed here yet, but GitHub already has content"),
        FailureKind.OperationInProgress => L.T("仓库存在未完成的 Git 操作", "An unfinished Git operation is in progress"),
        FailureKind.IndexLocked => L.T("仓库被其他 Git 程序锁定（index.lock）", "Another Git program has locked the repository (index.lock)"),
        FailureKind.LargeFile => L.T("存在超过 GitHub 限制的大文件", "A file is larger than GitHub allows"),
        FailureKind.MissingIdentity => L.T("未配置 Git 提交者身份", "No Git name and email are set"),
        FailureKind.PushRejected => L.T("上传被拒绝：远程有新的提交", "Upload rejected: GitHub has newer commits"),
        FailureKind.MergeBlocked => L.T("整合远程更新被阻止：会覆盖本地未提交的文件", "Merging was blocked: it would overwrite local files"),
        FailureKind.UnrelatedHistories => L.T("本地与远程历史不相关，无法自动合并", "The local and GitHub histories are unrelated"),
        FailureKind.GitUnavailable => L.T("无法运行 Git", "Git can't be run"),
        FailureKind.FileLocked => L.T("有文件正被其他程序打开，无法更新", "A file is open in another program and can't be updated"),
        _ => L.T($"{stage.DisplayName()}失败", $"{stage.DisplayName()} failed"),
    };

    public static string Suggestion(FailureKind kind) => kind switch
    {
        FailureKind.Authentication => L.T("请在「设置 › GitHub 账户」中重新登录（GitHub CLI、Git 凭据管理器或个人访问令牌）。",
                                          "Sign in again in Settings › GitHub Account (GitHub CLI, Git Credential Manager or a personal access token)."),
        FailureKind.RepositoryNotFound => L.T("如果仓库已在 GitHub 上删除，可在「更多」中把这个文件夹重新发布到新仓库，或从列表移除。否则请确认登录的账号对该仓库有读写权限。",
                                              "If the repository was deleted on GitHub, publish the folder to a new one from More, or remove it from the list. Otherwise make sure the signed-in account can read and write it."),
        FailureKind.Network => L.T("请检查网络连接或代理设置。网络恢复后 GitSync 会自动重试。",
                                   "Check the network or proxy. GitSync retries when the connection is back."),
        FailureKind.ServerUnavailable => L.T("GitHub 可能正在维护或网络不稳定，可稍后重试，或访问 githubstatus.com 查看服务状态。",
                                             "GitHub may be under maintenance. Try again later, or check githubstatus.com."),
        FailureKind.Timeout => L.T("可能是网络过慢或文件过大。已终止该操作，没有修改任何文件。可稍后重试。",
                                   "The network may be slow or a file too large. Nothing was changed; try again later."),
        FailureKind.FolderMissing => L.T("文件夹可能被移动、重命名或所在磁盘未连接。请重新定位，或从 GitHub 重新下载。",
                                         "The folder may have been moved or renamed, or its drive isn't connected. Locate it again, or download it from GitHub."),
        FailureKind.PermissionDenied => L.T("请确认当前 Windows 账户对该文件夹有读写权限，或把仓库移到「文档」等个人文件夹中。",
                                            "Make sure your Windows account can read and write the folder, or move it into a personal folder such as Documents."),
        FailureKind.NotARepository => L.T("请选择通过 GitHub Desktop 克隆或发布过的仓库文件夹（其中包含 .git 目录）。",
                                          "Choose a folder cloned or published with GitHub Desktop (it contains a .git folder)."),
        FailureKind.NoRemote => L.T("请先在 GitHub Desktop 中发布（Publish）该仓库，或执行 git remote add origin <地址>。",
                                    "Publish the repository in GitHub Desktop first, or run git remote add origin <url>."),
        FailureKind.DetachedHead => L.T("请在 GitHub Desktop 中切换回一个分支（例如 main）后再同步。",
                                        "Switch back to a branch (such as main) in GitHub Desktop, then sync."),
        FailureKind.UnbornWithRemote => L.T("GitHub 上已有内容，但本地文件夹里有同名文件，GitSync 不会覆盖它们。请把这些文件移到别处，再点「立即同步」。",
                                            "GitHub already has content, but the folder has files with the same names, and GitSync won't overwrite them. Move them elsewhere, then click Sync Now."),
        FailureKind.OperationInProgress => L.T("请在 GitHub Desktop 或终端中完成或中止该操作；也可以在「更多」菜单中选择中止（需要确认）。",
                                               "Finish or abort it in GitHub Desktop or a terminal, or choose Abort in the More menu."),
        FailureKind.IndexLocked => L.T("可能是 GitHub Desktop 等程序正在执行 Git 操作，稍后会自动重试。若确认没有任何 Git 程序在运行，可删除仓库中的 .git\\index.lock。",
                                       "Another program such as GitHub Desktop may be running Git; GitSync retries later. If nothing is running, delete .git\\index.lock."),
        FailureKind.LargeFile => L.T("GitHub 单个文件上限 100 MB。请将大文件移出仓库、压缩拆分，或使用 Git LFS。",
                                     "GitHub allows files up to 100 MB. Move large files out, split them, or use Git LFS."),
        FailureKind.MissingIdentity => L.T("请登录 GitHub 账户后重试，或在 GitHub Desktop 的设置中配置 Git 名称和邮箱。",
                                           "Sign in to GitHub and retry, or set a Git name and email in GitHub Desktop."),
        FailureKind.PushRejected => L.T("远程在同步期间发生了变化，已多次重试仍失败。请稍后再次同步。",
                                        "GitHub changed during the sync and retries failed. Sync again later."),
        FailureKind.MergeBlocked => L.T("本地有未提交的文件与远程更新冲突。请查看 Git 输出中列出的文件，移动或备份后重试。",
                                        "Uncommitted local files clash with the update. Move or back up the files listed in the Git output, then retry."),
        FailureKind.UnrelatedHistories => L.T("本地仓库和 GitHub 仓库不是同一个历史。请确认选择了正确的文件夹。",
                                              "The folder and the GitHub repository have different histories. Make sure you picked the right folder."),
        FailureKind.GitUnavailable => L.T("请安装 Git for Windows，或在设置中指定 git.exe 的位置。",
                                          "Install Git for Windows, or choose git.exe in Settings."),
        FailureKind.FileLocked => L.T("Windows 上被 Word、Excel 等打开的文件不能被替换。请关闭这些文件（不保存）后再点「立即同步」。",
                                      "On Windows, files open in Word, Excel and similar apps can't be replaced. Close them without saving, then click Sync Now."),
        _ => L.T("请查看下方 Git 输出了解详情。", "See the Git output below for details."),
    };
}
