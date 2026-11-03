import Foundation

/// Turns git output into a failure kind plus Chinese explanations.
public enum GitErrorClassifier {
    private static let rules: [(FailureKind, [String])] = [
        (.largeFile, [
            "exceeds github's file size limit", "gh001", "large files detected",
            "this exceeds github", "file size limit of 100",
        ]),
        (.repositoryNotFound, ["repository not found", "error: 404"]),
        (.authentication, [
            "authentication failed", "could not read username", "could not read password",
            "terminal prompts disabled", "invalid username or password", "permission denied (publickey)",
            "the requested url returned error: 401", "the requested url returned error: 403",
            "bad credentials", "support for password authentication was removed",
            "permission to ", "denied to ", "host key verification failed",
            "write access to repository not granted",
        ]),
        (.serverUnavailable, [
            "the requested url returned error: 500", "the requested url returned error: 502",
            "the requested url returned error: 503", "the requested url returned error: 504",
            "internal server error", "service unavailable", "remote end hung up unexpectedly",
            "rpc failed", "unexpected disconnect",
        ]),
        (.network, [
            "could not resolve host", "failed to connect", "connection timed out",
            "network is unreachable", "couldn't connect to server", "connection refused",
            "no route to host", "operation timed out", "ssl_error_syscall",
            "connection reset by peer", "could not resolve hostname", "unable to access",
            "temporary failure in name resolution", "nodename nor servname provided",
        ]),
        (.indexLocked, ["index.lock", "another git process seems to be running"]),
        (.missingIdentity, ["please tell me who you are", "unable to auto-detect email address"]),
        (.unrelatedHistories, ["refusing to merge unrelated histories"]),
        (.mergeBlocked, [
            "would be overwritten by merge", "untracked working tree files would be",
            "your local changes to the following files would be overwritten",
            "not possible to fast-forward",
        ]),
        (.pushRejected, ["[rejected]", "non-fast-forward", "fetch first", "failed to push some refs"]),
        (.permissionDenied, ["operation not permitted", "permission denied"]),
        (.notARepository, ["not a git repository"]),
        (.noRemote, ["'origin' does not appear to be a git repository", "no such remote"]),
    ]

    public static func classify(output: String, timedOut: Bool) -> FailureKind {
        if timedOut { return .timeout }
        let text = output.lowercased()
        // Rules are ordered: specific causes (401/403/5xx) come before the generic
        // "unable to access" that git prints alongside them.
        for (kind, needles) in rules where needles.contains(where: text.contains) {
            return kind
        }
        return .unknown
    }

    public static func message(for kind: FailureKind, stage: SyncStage) -> String {
        switch kind {
        case .authentication: "GitHub 认证失败（\(stage.displayName)）"
        case .repositoryNotFound: "找不到 GitHub 仓库，或当前账号无权访问该私有仓库"
        case .network: "无法连接 GitHub，网络不可用"
        case .serverUnavailable: "GitHub 服务器暂时不可用"
        case .timeout: "Git 操作超时（\(stage.displayName)）"
        case .folderMissing: "本地文件夹不存在或已被移动"
        case .permissionDenied: "没有访问该文件夹的权限"
        case .notARepository: "所选文件夹不是 Git 仓库"
        case .noRemote: "仓库没有配置远程 origin"
        case .detachedHead: "仓库处于分离 HEAD 状态，不在任何分支上"
        case .unbornWithRemote: "本地仓库尚无提交，而远程分支已有内容"
        case .operationInProgress: "仓库存在未完成的 Git 操作"
        case .indexLocked: "仓库被其他 Git 程序锁定（index.lock）"
        case .largeFile: "存在超过 GitHub 限制的大文件"
        case .missingIdentity: "未配置 Git 提交者身份"
        case .pushRejected: "上传被拒绝：远程有新的提交"
        case .mergeBlocked: "整合远程更新被阻止：会覆盖本地未提交的文件"
        case .unrelatedHistories: "本地与远程历史不相关，无法自动合并"
        case .gitUnavailable: "无法运行 Git"
        case .unknown: "\(stage.displayName)失败"
        }
    }

    public static func suggestion(for kind: FailureKind) -> String {
        switch kind {
        case .authentication:
            "请在「设置 › GitHub 账户」中重新登录（OAuth、GitHub CLI 或个人访问令牌）。如果使用 SSH 地址，请确认 ssh-agent 中已加载密钥。"
        case .repositoryNotFound:
            "确认远程地址正确，并确认登录的 GitHub 账号对该私有仓库有读写权限；使用令牌时需要 repo 权限（细粒度令牌需对该仓库授予 Contents 读写）。"
        case .network:
            "请检查网络连接或代理设置。网络恢复后 GitCloud Sync 会自动重试。"
        case .serverUnavailable:
            "GitHub 可能正在维护或网络不稳定，可稍后重试，或访问 githubstatus.com 查看服务状态。"
        case .timeout:
            "可能是网络过慢或文件过大。已终止该操作，没有修改任何文件。可稍后重试。"
        case .folderMissing:
            "文件夹可能被移动、重命名或所在磁盘未连接。请恢复文件夹位置，或移除该仓库后重新添加。"
        case .permissionDenied:
            "请在「系统设置 › 隐私与安全性 › 完全磁盘访问权限 / 文件与文件夹」中允许 GitCloud Sync 访问该位置。"
        case .notARepository:
            "请选择通过 GitHub Desktop 克隆或发布过的仓库文件夹（其中包含 .git 目录）。"
        case .noRemote:
            "请先在 GitHub Desktop 中使用「Publish repository」发布该仓库，或执行 git remote add origin <地址>。"
        case .detachedHead:
            "请在 GitHub Desktop 中切换回一个分支（例如 main）后再同步。"
        case .unbornWithRemote:
            "请在 GitHub Desktop 中先拉取（Pull）远程内容，再使用自动同步。"
        case .operationInProgress:
            "请在 GitHub Desktop 或终端中完成或中止该操作；也可以在「更多」菜单中选择中止（需要确认）。GitCloud Sync 不会自动清理。"
        case .indexLocked:
            "可能是 GitHub Desktop 等程序正在执行 Git 操作，稍后会自动重试。若确认没有任何 Git 程序在运行，可删除仓库中的 .git/index.lock。"
        case .largeFile:
            "GitHub 单个文件上限 100 MB。请将大文件移出仓库、压缩拆分，或使用 Git LFS。若大文件已被提交，需要先在 GitHub Desktop 中撤销该提交。"
        case .missingIdentity:
            "请在 GitHub Desktop 的设置中配置 Git 名称和邮箱，或登录 GitHub 账户后重试。"
        case .pushRejected:
            "远程在同步期间发生了变化，已多次重试仍失败。请稍后再次同步。"
        case .mergeBlocked:
            "本地有未提交（可能因超过大小限制被跳过）的文件与远程更新冲突。请查看 Git 输出中列出的文件，移动或备份后重试。"
        case .unrelatedHistories:
            "本地仓库和 GitHub 仓库不是同一个历史。请确认选择了正确的文件夹，或在 GitHub Desktop 中重新克隆。"
        case .gitUnavailable:
            "请安装 Xcode Command Line Tools（xcode-select --install）或 Homebrew Git，或在设置中指定 git 路径。"
        case .unknown:
            "请查看下方 Git 输出了解详情，复制错误信息后可在 GitHub Desktop 或终端中进一步检查。"
        }
    }
}
