import AppKit
import Foundation
import Observation

/// Runtime-only state for one repository.
struct RepoRuntime {
    var info: RepositoryInfo?
    var phase: SyncPhase?
    var isSyncing = false
    var warnings: [String] = []
    var lastSteps: [SyncStepRecord] = []
    var usage: RepositoryUsage?
    var measuringUsage = false
    /// Set when the folder was found in the Trash.
    var trashedURL: URL?
    /// Possible new locations of a folder that can't be found.
    var candidates: [URL] = []
    var searchingCandidates = false
    /// Downloading the repository from GitHub again after its folder was deleted.
    var downloading = false
}

enum SyncTrigger: String {
    case manualSingle, manualAll, scheduled, startup, wake, networkRestored, conflictResolution, restore, enabled

    var isManual: Bool { self == .manualSingle || self == .manualAll || self == .conflictResolution || self == .restore }

    var displayName: String {
        switch self {
        case .manualSingle, .manualAll: String(localized: "手动同步")
        case .scheduled: String(localized: "定时同步")
        case .startup: String(localized: "启动同步")
        case .wake: String(localized: "唤醒后同步")
        case .networkRestored: String(localized: "网络恢复后同步")
        case .conflictResolution: String(localized: "解决冲突")
        case .restore: String(localized: "恢复历史版本")
        case .enabled: String(localized: "开启自动同步")
        }
    }
}

enum AppSheet: Identifiable {
    case errorDetail(UUID)
    case conflicts(UUID)
    case createRepository(URL)
    case deleteRepository(UUID, github: Bool, local: Bool)
    case storage(UUID)
    case deviceFlow
    case downloadFromGitHub

    var id: String {
        switch self {
        case .errorDetail(let id): "error-\(id)"
        case .conflicts(let id): "conflict-\(id)"
        case .createRepository(let url): "create-\(url.path)"
        case .deleteRepository(let id, _, _): "delete-\(id)"
        case .storage(let id): "storage-\(id)"
        case .deviceFlow: "device-flow"
        case .downloadFromGitHub: "download-from-github"
        }
    }
}

enum CreationOutcome {
    case created
    case failed(String)
    /// The name is taken by an empty repository of the same account, which can be linked instead.
    case nameTakenButEmpty(String)
}

enum DeletionOutcome {
    case done
    case failed(String)
    /// GitHub refused: the token lacks the delete_repo permission.
    case needsDeleteScope
}

struct AppAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// The app's single source of truth (MVVM view model).
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    var settings: AppSettings {
        didSet { settingsDidChange(from: oldValue) }
    }
    private(set) var repositories: [RepositoryConfig] = []
    private(set) var runtime: [UUID: RepoRuntime] = [:]
    private(set) var gitEnvironment: GitEnvironment?
    private(set) var gitProblem: String?
    private(set) var isOnline = true
    private(set) var nextSyncDate: Date?
    private(set) var isShuttingDown = false
    var activeSheet: AppSheet?
    var alert: AppAlert? {
        didSet { if alert == nil { showNextCreation() } }
    }
    /// Plain folders waiting for the "create on GitHub" sheet, one at a time.
    @ObservationIgnored private var pendingCreations: [URL] = []

    let logStore = LogStore()
    let auth = GitHubAuthService()
    let loginItem = LoginItemService()

    @ObservationIgnored private let notifications = NotificationService()
    @ObservationIgnored private let networkMonitor = NetworkMonitor()
    @ObservationIgnored private let store = JSONFileStore<PersistedState>(
        url: JSONFileStore<PersistedState>.applicationSupportURL(fileName: "state.json")
    )
    @ObservationIgnored private let coordinator: SyncCoordinator
    @ObservationIgnored private var schedulerTask: Task<Void, Never>?
    @ObservationIgnored private var syncTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var isRestoring = true
    @ObservationIgnored private var started = false

    private init() {
        var loaded = PersistedState()
        var loadError: String?
        do {
            loaded = try store.load() ?? PersistedState()
        } catch {
            loadError = error.localizedDescription
            // Keep the unreadable file for inspection instead of overwriting it.
            let backup = store.url.deletingPathExtension().appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: store.url, to: backup)
        }
        let migrated = loaded.migrate()
        settings = loaded.settings
        repositories = loaded.repositories
        coordinator = SyncCoordinator(maxConcurrent: loaded.settings.maxConcurrentSyncs)
        isRestoring = false
        if migrated {
            persist()
            log(nil, String(localized: "配置"), .info, String(localized: "自动同步改为由每个仓库的开关单独控制"))
        }
        if let loadError {
            log(nil, String(localized: "配置"), .error, String(localized: "读取配置失败，已备份旧文件并使用默认配置"), detail: loadError)
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        applyDockPolicy()
        notifications.requestAuthorization()
        log(nil, String(localized: "启动"), .info, String(localized: "GitSync 已启动，管理 \(repositories.count) 个仓库"))

        networkMonitor.start { online in
            Task { @MainActor in AppModel.shared.networkChanged(online: online) }
        }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in AppModel.shared.handleWake() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                for repo in AppModel.shared.repositories { AppModel.shared.followFolder(repo.id) }
            }
        }
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in AppModel.shared.log(nil, String(localized: "系统"), .info, String(localized: "系统即将休眠")) }
        }

        Task {
            await detectGit()
            await auth.refresh()
            logAuthState()
            await refreshAllInfo()
            if autoSyncCount > 0 {
                log(nil, String(localized: "自动同步"), .info, String(localized: "\(autoSyncCount) 个仓库自动同步中（每 \(settings.intervalMinutes) 分钟）"))
            }
            restartScheduler(runImmediately: true)
        }
    }

    func detectGit() async {
        switch await GitEnvironment.detect(customPath: settings.customGitPath) {
        case .success(let env):
            gitEnvironment = env
            gitProblem = nil
            auth.gitEnvironment = env
            log(nil, String(localized: "环境"), .info, String(localized: "使用 \(env.gitURL.path)（\(env.version)）"))
        case .failure(let error):
            gitEnvironment = nil
            gitProblem = error.localizedDescription
            log(nil, String(localized: "环境"), .error, String(localized: "未找到可用的 Git"), detail: error.localizedDescription)
        }
    }

    var hasRunningSyncs: Bool { !syncTasks.isEmpty }

    /// Stops scheduling and waits (bounded) for running syncs before the app quits.
    func prepareForTermination(timeout: TimeInterval = 30) async {
        isShuttingDown = true
        schedulerTask?.cancel()
        schedulerTask = nil
        let deadline = Date().addingTimeInterval(timeout)
        if !syncTasks.isEmpty {
            log(nil, String(localized: "退出"), .info, String(localized: "等待 \(syncTasks.count) 个正在进行的同步完成…"))
        }
        while !syncTasks.isEmpty, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
        if !syncTasks.isEmpty {
            log(nil, String(localized: "退出"), .warning, String(localized: "仍有同步未完成，Git 进程将独立运行至结束；下次启动会重新检查仓库状态"))
        }
        persist()
        logStore.flush()
    }

    // MARK: - Repositories

    func addRepositories(urls: [URL]) async {
        guard let git = gitEnvironment else {
            alert = AppAlert(title: String(localized: "无法添加仓库"), message: gitProblem ?? String(localized: "未找到 Git"))
            return
        }
        var problems: [String] = []
        var added: [UUID] = []
        for url in urls {
            if let reason = RepositoryCreator.refusalReason(for: url) {
                problems.append(reason)
                continue
            }
            let client = GitClient(repositoryURL: url, git: git)
            do {
                let info = try await RepositoryInspector(client: client).inspect()
                if info.remoteURL == nil,
                   RepositoryCreator.canonicalPath(info.topLevelPath) == RepositoryCreator.canonicalPath(url.path) {
                    // A local-only repository: offer to create its GitHub repository.
                    pendingCreations.append(url)
                    continue
                }
                if repositories.contains(where: { $0.path == info.topLevelPath }) {
                    problems.append(String(localized: "「\(url.lastPathComponent)」已经在列表中。"))
                    continue
                }
                var config = RepositoryConfig(
                    path: info.topLevelPath,
                    displayName: URL(fileURLWithPath: info.topLevelPath).lastPathComponent
                )
                config.bookmark = RepositoryLocator.bookmark(for: URL(fileURLWithPath: info.topLevelPath))
                config.knownRemote = info.remoteURL
                repositories.append(config)
                added.append(config.id)
                runtime[config.id, default: RepoRuntime()].info = info
                var detail = String(localized: "路径：\(info.topLevelPath)\n分支：\(info.branch ?? String(localized: "（分离 HEAD）"))\n远程：\(info.remoteURL ?? String(localized: "未配置"))")
                detail += String(localized: "\n未提交修改：\(info.changedFiles) 个，领先 \(info.ahead)，落后 \(info.behind)")
                log(config.id, String(localized: "添加仓库"), .success, String(localized: "已添加仓库 \(config.displayName)"), detail: detail)
                if info.topLevelPath != url.standardizedFileURL.path && info.topLevelPath != url.resolvingSymlinksInPath().path {
                    problems.append(String(localized: "「\(url.lastPathComponent)」位于仓库内部，已改为添加仓库根目录：\(info.topLevelPath)"))
                }
                if info.remoteURL == nil {
                    problems.append(String(localized: "「\(config.displayName)」没有配置远程 origin，请先在 GitHub Desktop 中发布（Publish）后再同步。"))
                } else if !info.isGitHubRemote {
                    problems.append(String(localized: "「\(config.displayName)」的远程不是 GitHub（\(info.remoteURL ?? "")），将使用系统凭据进行同步。"))
                }
                if let op = info.inProgressOperation {
                    problems.append(String(localized: "「\(config.displayName)」有未完成的\(op.displayName)，需要先处理才能同步。"))
                }
            } catch let failure as SyncFailure where failure.kind == .notARepository {
                pendingCreations.append(url)
            } catch let failure as SyncFailure {
                problems.append("「\(url.lastPathComponent)」：\(failure.message)\n\(failure.suggestion)")
            } catch {
                problems.append("「\(url.lastPathComponent)」：\(error.localizedDescription)")
            }
        }
        persist()
        // A new repository's switch starts on, so it syncs right away like any switch turned on.
        for id in added where repository(id)?.autoSyncEnabled == true {
            sync(id, trigger: .enabled)
        }
        if !problems.isEmpty {
            alert = AppAlert(title: String(localized: "添加仓库"), message: problems.joined(separator: "\n\n"))
        }
        showNextCreation()
    }

    // MARK: - New GitHub repositories

    /// Presents the next queued "create on GitHub" sheet once nothing else is on screen.
    func showNextCreation() {
        guard activeSheet == nil, alert == nil, !pendingCreations.isEmpty else { return }
        activeSheet = .createRepository(pendingCreations.removeFirst())
    }

    func previewFolder(_ url: URL) async throws -> FolderPreview {
        guard let git = gitEnvironment else {
            throw SyncFailure(kind: .gitUnavailable, stage: .inspect, stderr: gitProblem ?? "")
        }
        let limit = Int64(max(1, settings.largeFileLimitMB)) * 1024 * 1024
        return try await RepositoryCreator(git: git).preview(folder: url, largeFileLimit: limit, ignorePatterns: settings.ignorePatterns)
    }

    /// Creates `name` on GitHub (or links an empty repository of that name), prepares the folder,
    /// adds it to the list and starts the first sync, which uploads every file.
    func createGitHubRepository(folder: URL, name: String, isPrivate: Bool, description: String, linkExisting: Bool) async -> CreationOutcome {
        guard let git = gitEnvironment else { return .failed(gitProblem ?? String(localized: "未找到 Git")) }
        guard let credential = await auth.credentialForGit() else {
            return .failed(String(localized: "需要先在「设置 › GitHub 账户」中登录 GitHub。仅使用系统凭据助手或 SSH 时，无法自动创建仓库。"))
        }
        let creator = RepositoryCreator(git: git)
        let login = auth.user?.login
        let remoteURL: String
        do {
            if linkExisting {
                guard let login else { return .failed(String(localized: "无法确定当前 GitHub 账号，请在设置中重新检测登录状态。")) }
                remoteURL = "https://github.com/\(login)/\(name).git"
                guard try await creator.remoteIsEmpty(remoteURL, credential: credential, in: folder) else {
                    return .failed(String(localized: "GitHub 上的「\(login)/\(name)」已有内容，不能直接关联。请换一个仓库名。"))
                }
                log(nil, String(localized: "创建仓库"), .info, String(localized: "关联已有的空仓库 \(login)/\(name)"))
            } else {
                do {
                    let repo = try await GitHubAPI.createRepository(token: credential.token, name: name,
                                                                    isPrivate: isPrivate, description: description)
                    remoteURL = repo.cloneURL
                    log(nil, String(localized: "创建仓库"), .success, (isPrivate ? String(localized: "已在 GitHub 创建私有仓库 \(repo.fullName)") : String(localized: "已在 GitHub 创建公开仓库 \(repo.fullName)")),
                        detail: String(localized: "本地文件夹：\(folder.path)\n\(repo.htmlURL.absoluteString)"))
                } catch GitHubAPIError.nameTaken {
                    if let login, (try? await creator.remoteIsEmpty("https://github.com/\(login)/\(name).git",
                                                                     credential: credential, in: folder)) == true {
                        return .nameTakenButEmpty("\(login)/\(name)")
                    }
                    return .failed(String(localized: "你的 GitHub 账号下已经有名为「\(name)」的仓库，请换一个名字。"))
                }
            }
            try await creator.prepare(folder: folder, remoteURL: remoteURL, identity: auth.identity,
                                      ignorePatterns: settings.ignorePatterns)
        } catch let error as GitHubAPIError {
            return .failed(error.localizedDescription)
        } catch let failure as SyncFailure {
            return .failed(failure.message + (failure.stderr.isEmpty ? "" : "\n\n" + failure.stderr))
        } catch {
            return .failed(error.localizedDescription)
        }

        let path = RepositoryCreator.canonicalPath(folder.path)
        if let existing = repositories.first(where: { RepositoryCreator.canonicalPath($0.path) == path }) {
            // A local-only folder already in the list (for example after its GitHub repository was deleted).
            update(existing.id) {
                $0.autoSyncEnabled = true
                $0.lastMessage = nil
            }
            await refreshInfo(existing.id)
        } else {
            await addRepositories(urls: [folder])
        }
        if let repo = repositories.first(where: { RepositoryCreator.canonicalPath($0.path) == path }),
           runtime[repo.id]?.isSyncing != true {
            sync(repo.id, trigger: .manualSingle)
        }
        return .created
    }

    // MARK: - Deleting the GitHub repository or the local folder

    /// Counts what exists on only one side. `includeRemote` fetches from GitHub first.
    func deletionCheck(_ id: UUID, includeRemote: Bool) async throws -> DeletionCheck {
        guard let repo = repository(id), let git = gitEnvironment else {
            throw SyncFailure(kind: .gitUnavailable, stage: .inspect, stderr: gitProblem ?? "")
        }
        let credential = includeRemote ? await auth.credentialForGit() : nil
        let client = GitClient(repositoryURL: URL(fileURLWithPath: repo.path), git: git, credential: credential)
        return try await RepositoryRemoval(client: client).check(fetch: includeRemote)
    }

    /// Deletes the repository on GitHub and/or moves the local folder to the Trash. Each side is
    /// independent: deleting on GitHub leaves the folder (with its full history) as a local-only
    /// folder, and trashing the folder leaves GitHub untouched.
    func deleteRepository(_ id: UUID, onGitHub: Bool, local: Bool) async -> DeletionOutcome {
        guard let repo = repository(id), let git = gitEnvironment else { return .failed(gitProblem ?? String(localized: "未找到 Git")) }
        guard runtime[id]?.isSyncing != true, !(await coordinator.isRunning(id)) else {
            return .failed(String(localized: "\(repo.displayName) 正在同步，请等同步结束后再删除。"))
        }
        // Holding the syncing flag keeps the scheduler away while files are being removed.
        runtime[id, default: RepoRuntime()].isSyncing = true
        defer { runtime[id]?.isSyncing = false }
        let folder = URL(fileURLWithPath: repo.path)

        if onGitHub {
            await refreshInfo(id)
            guard let remote = runtime[id]?.info?.remoteURL,
                  let target = RepositoryRemoval.gitHubFullName(fromRemote: remote) else {
                return .failed(String(localized: "这个仓库的远程地址不是 GitHub，无法从这里删除。"))
            }
            guard let credential = await auth.credentialForGit() else {
                return .failed(String(localized: "需要先在「设置 › GitHub 账户」中登录 GitHub。"))
            }
            do {
                try await GitHubAPI.deleteRepository(token: credential.token, owner: target.owner, name: target.name)
                log(id, String(localized: "删除 GitHub 仓库"), .warning, String(localized: "已删除 GitHub 上的仓库 \(target.owner)/\(target.name)（本地文件夹保留）"))
            } catch GitHubAPIError.missingDeleteScope {
                auth.handleGitAuthFailure()   // drops the cached CLI token so a refreshed one is picked up
                return .needsDeleteScope
            } catch GitHubAPIError.notFound {
                log(id, String(localized: "删除 GitHub 仓库"), .warning, String(localized: "GitHub 上已经找不到 \(target.owner)/\(target.name)，按已删除处理"))
            } catch {
                return .failed(error.localizedDescription)
            }

            if !local {
                do {
                    let client = GitClient(repositoryURL: folder, git: git)
                    let renamed = try await RepositoryRemoval(client: client).detachDeletedRemote()
                    update(id) {
                        $0.autoSyncEnabled = false
                        $0.pausedForConflict = false
                        $0.conflictFiles = []
                        $0.lastStatus = .notSynced
                        $0.lastFailure = nil
                        $0.lastMessage = String(localized: "GitHub 上的仓库已删除，现在是仅本地的文件夹")
                    }
                    log(id, String(localized: "删除 GitHub 仓库"), .info, String(localized: "\(repo.displayName) 已改为仅本地，原远程改名为 \(renamed) 以保留已下载的提交"))
                } catch {
                    let message = (error as? SyncFailure)?.fullReport ?? error.localizedDescription
                    log(id, String(localized: "删除 GitHub 仓库"), .error, String(localized: "GitHub 仓库已删除，但更新本地远程设置失败"), detail: message)
                    return .failed(String(localized: "GitHub 上的仓库已删除，但更新本地设置失败：\n\(message)"))
                }
                await refreshInfo(id)
            }
        }

        if local {
            do {
                var trashed: NSURL?
                try FileManager.default.trashItem(at: folder, resultingItemURL: &trashed)
                log(id, String(localized: "删除本地文件夹"), .warning, String(localized: "已将 \(repo.path) 移到废纸篓\(onGitHub ? "" : String(localized: "（GitHub 上的仓库保留）"))"),
                    detail: trashed?.path)
            } catch {
                return .failed((onGitHub ? String(localized: "GitHub 上的仓库已删除，但") : "") + String(localized: "无法把文件夹移到废纸篓：\(error.localizedDescription)"))
            }
            removeRepository(id)
        }
        return .done
    }

    /// Removes the repository from the list only. Files and the GitHub repository are untouched.
    func removeRepository(_ id: UUID) {
        guard let repo = repository(id) else { return }
        repositories.removeAll { $0.id == id }
        runtime[id] = nil
        log(nil, String(localized: "移除仓库"), .info, String(localized: "已从列表移除 \(repo.displayName)（本地文件与 GitHub 仓库均未改动）"))
        persist()
    }

    /// A repository's switch is the only auto-sync control: turning it on syncs right away and then
    /// on every interval.
    /// Reorders the list (drag and drop in manual order). The menu bar panel follows the same order.
    func moveRepositories(from source: IndexSet, to destination: Int) {
        repositories.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    func setAutoSync(_ enabled: Bool, for id: UUID) {
        guard let repo = repository(id), repo.autoSyncEnabled != enabled else { return }
        update(id) { $0.autoSyncEnabled = enabled }
        log(id, String(localized: "设置"), .info, (enabled ? String(localized: "\(repo.displayName) 自动同步已开启") : String(localized: "\(repo.displayName) 自动同步已关闭")))
        if enabled { sync(id, trigger: .enabled) }
    }

    /// Flips every repository's switch at once (for example on a metered connection).
    func setAutoSyncForAll(_ enabled: Bool) {
        let changed = repositories.filter { $0.autoSyncEnabled != enabled }.map(\.id)
        guard !changed.isEmpty else { return }
        for id in changed {
            update(id) { $0.autoSyncEnabled = enabled }
        }
        log(nil, String(localized: "自动同步"), .info, enabled ? String(localized: "已开启全部 \(changed.count) 个仓库的自动同步") : String(localized: "已暂停全部仓库的自动同步"))
        if enabled {
            for id in changed { sync(id, trigger: .enabled) }
        }
    }

    /// Repositories that sync on the schedule.
    var autoSyncCount: Int {
        repositories.filter { $0.autoSyncEnabled && !$0.pausedForConflict }.count
    }

    func repository(_ id: UUID) -> RepositoryConfig? {
        repositories.first { $0.id == id }
    }

    func displayStatus(for repo: RepositoryConfig) -> SyncStatus {
        let rt = runtime[repo.id]
        if let phase = rt?.phase { return phase.status }
        if rt?.isSyncing == true { return .pending }
        return repo.lastStatus
    }

    func refreshInfo(_ id: UUID) async {
        followFolder(id)
        guard let git = gitEnvironment, let repo = repository(id) else { return }
        let folder = URL(fileURLWithPath: repo.path)
        let client = GitClient(repositoryURL: folder, git: git)
        do {
            let info = try await RepositoryInspector(client: client).inspect()
            runtime[id, default: RepoRuntime()].info = info
            // Remember what this repository looks like so it can be recognised after a move.
            let identity = await RepositoryLocator(git: git).identity(of: folder)
            if repo.knownRemote != identity.remote || repo.knownCommit != identity.commit {
                update(id) {
                    $0.knownRemote = identity.remote ?? $0.knownRemote
                    $0.knownCommit = identity.commit ?? $0.knownCommit
                }
            }
        } catch let failure as SyncFailure {
            runtime[id, default: RepoRuntime()].info = nil
            if failure.kind == .folderMissing || failure.kind == .notARepository || failure.kind == .permissionDenied {
                update(id) {
                    $0.lastStatus = .failed
                    $0.lastFailure = failure
                    $0.lastMessage = failure.message
                }
            }
            if failure.kind == .folderMissing { Task { await findCandidates(id) } }
        } catch {}
    }

    /// Repository-relative paths with changes that are not synced yet (from `git status`).
    func unsyncedPaths(_ id: UUID) async -> Set<String> {
        guard let repo = repository(id), let git = gitEnvironment else { return [] }
        let client = GitClient(repositoryURL: URL(fileURLWithPath: repo.path), git: git)
        guard let result = try? await client.run(["status", "--porcelain=v1", "-z", "--untracked-files=all"], timeout: 60),
              result.succeeded else { return [] }
        return Set(StatusEntry.parse(result.stdoutData).map(\.path))
    }

    // MARK: - Moved folders

    /// Follows a folder that was moved or renamed (via its bookmark). Returns false when the
    /// folder can't be used where it is: missing, or in the Trash.
    @discardableResult
    func followFolder(_ id: UUID) -> Bool {
        guard let repo = repository(id) else { return false }
        switch RepositoryLocator.locate(path: repo.path, bookmark: repo.bookmark) {
        case .unchanged:
            runtime[id]?.trashedURL = nil
            if repo.bookmark == nil {
                update(id) { $0.bookmark = RepositoryLocator.bookmark(for: URL(fileURLWithPath: repo.path)) }
            }
            return true
        case .moved(let url):
            let renamed = url.lastPathComponent != URL(fileURLWithPath: repo.path).lastPathComponent
            adopt(id, folder: url, message: String(localized: "\(repo.displayName) 已移动到 \(url.path)，继续同步"))
            if renamed { Task { await renameRemoteToMatchFolder(id) } }
            return true
        case .inTrash(let url):
            runtime[id, default: RepoRuntime()].trashedURL = url
            return false
        case .missing:
            runtime[id]?.trashedURL = nil
            return false
        }
    }

    /// Points the repository at `folder`, keeping its settings, status and history.
    private func adopt(_ id: UUID, folder: URL, message: String) {
        guard let repo = repository(id) else { return }
        let oldName = URL(fileURLWithPath: repo.path).lastPathComponent
        update(id) {
            $0.path = folder.path
            $0.bookmark = RepositoryLocator.bookmark(for: folder)
            if $0.displayName == oldName { $0.displayName = folder.lastPathComponent }
            if $0.lastFailure?.kind == .folderMissing {
                $0.lastFailure = nil
                $0.lastStatus = .notSynced
                $0.lastMessage = nil
            }
        }
        runtime[id]?.trashedURL = nil
        runtime[id]?.candidates = []
        log(id, String(localized: "文件夹位置"), .info, message)
        Task { await refreshUsage(id, force: true) }
    }

    /// After the folder was renamed, gives the GitHub repository the same name (in pinyin and with
    /// dashes where GitHub needs it), then points `origin` at the new URL.
    func renameRemoteToMatchFolder(_ id: UUID) async {
        guard settings.renameRemoteWithFolder, let git = gitEnvironment else { return }
        // Don't change the remote under a running sync.
        while runtime[id]?.isSyncing == true { try? await Task.sleep(for: .seconds(1)) }
        guard let repo = repository(id),
              let remote = runtime[id]?.info?.remoteURL ?? repo.knownRemote,
              let target = RepositoryRemoval.gitHubFullName(fromRemote: remote) else { return }
        let newName = RepositoryNaming.suggestedName(for: URL(fileURLWithPath: repo.path).lastPathComponent)
        guard !newName.isEmpty, newName.lowercased() != target.name.lowercased() else { return }
        guard let credential = await auth.credentialForGit() else {
            log(id, String(localized: "仓库改名"), .warning, String(localized: "未登录 GitHub，GitHub 上的仓库名保持为 \(target.name)"))
            return
        }
        do {
            let renamed = try await GitHubAPI.renameRepository(token: credential.token, owner: target.owner,
                                                               name: target.name, to: newName)
            try await pointOrigin(id, at: renamed.cloneURL, git: git)
            log(id, String(localized: "仓库改名"), .success,
                String(localized: "GitHub 仓库已跟随文件夹改名：\(target.name) → \(newName)"), detail: renamed.htmlURL.absoluteString)
        } catch GitHubAPIError.nameTaken {
            log(id, String(localized: "仓库改名"), .warning,
                String(localized: "GitHub 上已有名为 \(newName) 的仓库，仓库名保持为 \(target.name)"))
        } catch {
            log(id, String(localized: "仓库改名"), .warning,
                String(localized: "GitHub 仓库没能跟着改名，仓库名保持为 \(target.name)"),
                detail: (error as? SyncFailure)?.fullReport ?? error.localizedDescription)
        }
    }

    /// Repositories whose GitHub name was already checked this launch.
    @ObservationIgnored private var checkedRemoteNames: Set<UUID> = []

    /// When the repository was renamed on GitHub (for example by this folder's other Mac), updates
    /// `origin` to the new name. Checked once per launch, after a successful sync.
    func followRemoteRename(_ id: UUID) async {
        guard checkedRemoteNames.insert(id).inserted, let git = gitEnvironment,
              let remote = runtime[id]?.info?.remoteURL,
              let target = RepositoryRemoval.gitHubFullName(fromRemote: remote),
              let credential = await auth.credentialForGit(),
              let current = try? await GitHubAPI.repository(token: credential.token, owner: target.owner, name: target.name),
              current.fullName.lowercased() != "\(target.owner)/\(target.name)".lowercased() else { return }
        do {
            try await pointOrigin(id, at: current.cloneURL, git: git)
            log(id, String(localized: "仓库改名"), .info, String(localized: "GitHub 仓库已改名为 \(current.fullName)，已更新远程地址"))
        } catch {
            log(id, String(localized: "仓库改名"), .warning, String(localized: "无法更新远程地址"),
                detail: (error as? SyncFailure)?.fullReport ?? error.localizedDescription)
        }
    }

    private func pointOrigin(_ id: UUID, at url: String, git: GitEnvironment) async throws {
        guard let repo = repository(id) else { return }
        let client = GitClient(repositoryURL: URL(fileURLWithPath: repo.path), git: git)
        let result = try await client.run(["remote", "set-url", "origin", url], timeout: 30)
        guard result.succeeded else {
            throw SyncFailure.from(result, stage: .preflight, command: "git remote set-url origin \(url)")
        }
        update(id) { $0.knownRemote = url }
        await refreshInfo(id)
    }

    /// Looks for the missing folder by name with Spotlight and keeps the ones that are this repository.
    func findCandidates(_ id: UUID) async {
        guard let repo = repository(id), let git = gitEnvironment, runtime[id]?.searchingCandidates != true else { return }
        runtime[id, default: RepoRuntime()].searchingCandidates = true
        defer { runtime[id]?.searchingCandidates = false }
        let expected = RepositoryIdentity(remote: repo.knownRemote, commit: repo.knownCommit)
        let found = await RepositoryLocator(git: git).candidates(named: URL(fileURLWithPath: repo.path).lastPathComponent,
                                                                  expected: expected)
        let taken = Set(repositories.map { RepositoryCreator.canonicalPath($0.path) })
        runtime[id]?.candidates = found.filter { !taken.contains(RepositoryCreator.canonicalPath($0.path)) }
    }

    /// Uses `folder` as the repository's new location after checking it is the same repository.
    /// Returns an error message, or nil on success.
    func relocate(_ id: UUID, to folder: URL) async -> String? {
        guard let repo = repository(id), let git = gitEnvironment else { return gitProblem }
        let path = RepositoryCreator.canonicalPath(folder.path)
        if let other = repositories.first(where: { $0.id != id && RepositoryCreator.canonicalPath($0.path) == path }) {
            return String(localized: "「\(folder.lastPathComponent)」已经是列表中的「\(other.displayName)」。")
        }
        let expected = RepositoryIdentity(remote: repo.knownRemote, commit: repo.knownCommit)
        guard await RepositoryLocator(git: git).matches(folder, expected: expected) else {
            return String(localized: "「\(folder.lastPathComponent)」不是「\(repo.displayName)」这个仓库：远程地址和提交记录都对不上。")
        }
        adopt(id, folder: folder, message: String(localized: "\(repo.displayName) 已重新定位到 \(folder.path)"))
        await refreshInfo(id)
        return nil
    }

    /// Downloads a repository whose folder was deleted from GitHub again, to its old place or to
    /// `folder`, then carries on syncing. Never replaces a folder that has files in it.
    func redownload(_ id: UUID, to folder: URL? = nil) async {
        guard let repo = repository(id), let git = gitEnvironment else { return }
        guard let remote = runtime[id]?.info?.remoteURL ?? repo.knownRemote else {
            alert = AppAlert(title: String(localized: "无法重新下载"),
                             message: String(localized: "不知道「\(repo.displayName)」对应的 GitHub 地址。请用「重新定位」选择文件夹。"))
            return
        }
        let destination = folder ?? URL(fileURLWithPath: repo.path)
        let path = RepositoryCreator.canonicalPath(destination.path)
        if let other = repositories.first(where: { $0.id != id && RepositoryCreator.canonicalPath($0.path) == path }) {
            alert = AppAlert(title: String(localized: "无法重新下载"),
                             message: String(localized: "「\(destination.lastPathComponent)」已经是列表中的「\(other.displayName)」。"))
            return
        }
        runtime[id, default: RepoRuntime()].downloading = true
        defer { runtime[id]?.downloading = false }
        log(id, String(localized: "重新下载"), .info, String(localized: "正在从 GitHub 下载 \(repo.displayName) 到 \(destination.path)"))
        do {
            try await RepositoryCreator(git: git).download(remoteURL: remote, to: destination,
                                                          credential: await auth.credentialForGit(),
                                                          identity: auth.identity, ignorePatterns: settings.ignorePatterns)
            adopt(id, folder: destination, message: String(localized: "已从 GitHub 重新下载 \(repo.displayName) 到 \(destination.path)"))
            await refreshInfo(id)
        } catch {
            let message = (error as? SyncFailure)?.message ?? error.localizedDescription
            log(id, String(localized: "重新下载"), .error, message)
            alert = AppAlert(title: String(localized: "无法重新下载"), message: message)
        }
    }

    // MARK: - Documents open in Office

    @ObservationIgnored private var automationNoticeShown = false
    private static let officeExtensions: Set<String> = [
        "doc", "docx", "docm", "dot", "dotx", "rtf", "xls", "xlsx", "xlsm", "xlsb", "csv", "ppt", "pptx", "pptm",
    ]

    /// After a sync downloaded new versions, reopens those that are open in Word, Excel or
    /// PowerPoint so they show the new content. Documents with unsaved edits are never touched
    /// without asking: the user chooses to keep both versions or use GitHub's.
    func refreshOpenDocuments(_ id: UUID, relativePaths: [String]) {
        guard let repo = repository(id) else { return }
        let root = URL(fileURLWithPath: repo.path)
        let candidates = Set(relativePaths
            .filter { Self.officeExtensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
            .map { root.appendingPathComponent($0).path }
            .filter { FileManager.default.fileExists(atPath: $0) }
            .filter(OfficeDocuments.probablyOpen))
        guard !candidates.isEmpty else { return }

        let (documents, problems) = OfficeDocuments.openDocuments(among: candidates)
        let stage = String(localized: "刷新打开的文档")
        for problem in problems {
            switch problem {
            case .notAllowed(let app):
                log(id, stage, .warning, String(localized: "没有控制 Office 的权限，无法刷新已打开的文档（\(app)）"))
                if !automationNoticeShown {
                    automationNoticeShown = true
                    notifications.post(
                        title: String(localized: "无法刷新 Office 中打开的文档"),
                        body: String(localized: "\(repo.displayName) 下载了新版本。如果文档正在 Word、Excel 或 PowerPoint 中打开，请关闭（不保存）后重新打开。要让 GitSync 自动刷新，请在「系统设置 › 隐私与安全性 › 自动化」中允许 GitSync 控制它们。"),
                        identifier: "office-permission")
                }
            case .script(let message):
                log(id, stage, .warning, String(localized: "读取打开的文档失败：\(message)"))
            }
        }

        for document in documents where document.saved {
            if let problem = OfficeDocuments.reopen(document) {
                log(id, stage, .warning, String(localized: "无法在 \(document.app.name) 中刷新「\(document.fileName)」：\(Self.describe(problem))"))
            } else {
                log(id, stage, .success, String(localized: "已在 \(document.app.name) 中刷新「\(document.fileName)」"))
                notifications.post(title: String(localized: "已在 \(document.app.name) 中刷新"),
                                   body: document.fileName, identifier: "office-\(document.path)")
            }
        }

        let edited = documents.filter { !$0.saved }
        guard !edited.isEmpty else { return }
        // Ask after the current update has finished, one document at a time.
        Task { @MainActor in
            for document in edited { askAboutEditedDocument(id, document) }
        }
    }

    private func askAboutEditedDocument(_ id: UUID, _ document: OfficeDocuments.OpenDocument) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "「\(document.fileName)」在 \(document.app.name) 里有未保存的修改")
        alert.informativeText = String(localized: "GitHub 上的新版本刚刚同步到这台 Mac。如果直接在 \(document.app.name) 里保存，会用你打开时的旧内容覆盖新版本。")
        alert.addButton(withTitle: String(localized: "两个都保留"))
        alert.addButton(withTitle: String(localized: "用云端版本"))
        alert.addButton(withTitle: String(localized: "稍后处理"))
        let stage = String(localized: "刷新打开的文档")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let copy = OfficeDocuments.copyPath(for: document.path)
            if let problem = OfficeDocuments.saveCopyAndReopen(document, copyPath: copy) {
                log(id, stage, .error, String(localized: "无法另存「\(document.fileName)」的修改：\(Self.describe(problem))"))
                self.alert = AppAlert(title: String(localized: "无法另存你的修改"),
                                      message: String(localized: "请在 \(document.app.name) 中用「文件 › 另存为」把修改存成另一个文件，再重新打开「\(document.fileName)」。"))
            } else {
                log(id, stage, .success, String(localized: "你的修改已另存为「\((copy as NSString).lastPathComponent)」，并打开了云端版本「\(document.fileName)」"))
            }
        case .alertSecondButtonReturn:
            if let problem = OfficeDocuments.reopen(document) {
                log(id, stage, .error, String(localized: "无法在 \(document.app.name) 中刷新「\(document.fileName)」：\(Self.describe(problem))"))
            } else {
                log(id, stage, .warning, String(localized: "已丢弃 \(document.app.name) 中未保存的修改，打开了云端版本「\(document.fileName)」"))
            }
        default:
            log(id, stage, .warning, String(localized: "「\(document.fileName)」在 \(document.app.name) 中仍是旧内容；保存前请先处理，否则会覆盖云端版本"))
        }
    }

    private static func describe(_ problem: OfficeDocuments.Problem) -> String {
        switch problem {
        case .notAllowed: String(localized: "没有控制权限")
        case .script(let message): message
        }
    }

    // MARK: - Download from GitHub

    /// The signed-in account's GitHub repositories, for picking one to download.
    func gitHubRepositories() async throws -> [GitHubRepositorySummary] {
        guard let credential = await auth.credentialForGit() else {
            throw GitHubAPIError.unauthorized
        }
        return try await GitHubAPI.listRepositories(token: credential.token)
    }

    /// The list entry already syncing `repository`, matched by its GitHub owner/name.
    func existingRepository(for repository: GitHubRepositorySummary) -> RepositoryConfig? {
        repositories.first { config in
            guard let remote = runtime[config.id]?.info?.remoteURL ?? config.knownRemote,
                  let name = RepositoryRemoval.gitHubFullName(fromRemote: remote) else { return false }
            return "\(name.owner)/\(name.name)".lowercased() == repository.fullName.lowercased()
        }
    }

    /// Where downloads go unless the user picks another place: next to the first repository, else Documents.
    var defaultDownloadFolder: URL {
        if let first = repositories.first {
            let parent = URL(fileURLWithPath: first.path).deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: parent.path) { return parent }
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    /// Permanently deletes a repository on GitHub that has no folder on this Mac. Repositories in
    /// the list go through `deleteRepository`, which also takes care of the local folder.
    func deleteGitHubRepository(_ repository: GitHubRepositorySummary) async -> DeletionOutcome {
        guard existingRepository(for: repository) == nil else {
            return .failed(String(localized: "这个仓库在列表中，请在它的仓库页「更多」菜单里删除。"))
        }
        let parts = repository.fullName.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return .failed(String(localized: "无法识别仓库名 \(repository.fullName)")) }
        guard let credential = await auth.credentialForGit() else {
            return .failed(String(localized: "未登录 GitHub"))
        }
        do {
            try await GitHubAPI.deleteRepository(token: credential.token, owner: parts[0], name: parts[1])
        } catch GitHubAPIError.missingDeleteScope {
            auth.handleGitAuthFailure()   // drops the cached CLI token so a refreshed one is picked up
            return .needsDeleteScope
        } catch GitHubAPIError.notFound {
            // Already gone.
        } catch {
            return .failed(error.localizedDescription)
        }
        log(nil, String(localized: "删除 GitHub 仓库"), .warning, String(localized: "已删除 GitHub 上的仓库 \(repository.fullName)"))
        return .done
    }

    /// Downloads a GitHub repository into `destination` and adds it to the list. Returns an error
    /// message, or nil on success.
    func downloadFromGitHub(_ repository: GitHubRepositorySummary, to destination: URL, autoSync: Bool) async -> String? {
        guard let git = gitEnvironment else { return gitProblem ?? String(localized: "未找到 Git") }
        if let reason = RepositoryCreator.refusalReason(for: destination) { return reason }
        do {
            try await RepositoryCreator(git: git).download(remoteURL: repository.cloneURL, to: destination,
                                                          credential: await auth.credentialForGit(),
                                                          identity: auth.identity, ignorePatterns: settings.ignorePatterns)
        } catch {
            return (error as? SyncFailure)?.message ?? error.localizedDescription
        }
        await addRepositories(urls: [destination])
        guard let added = repositories.first(where: { RepositoryCreator.canonicalPath($0.path) == RepositoryCreator.canonicalPath(destination.path) }) else {
            return nil
        }
        log(added.id, String(localized: "从 GitHub 下载"), .success,
            String(localized: "已从 GitHub 下载 \(repository.fullName) 到 \(destination.path)"))
        // Show it in the main window (the sidebar keeps its selection in this default).
        UserDefaults.standard.set(added.id.uuidString, forKey: "repositoryList.selection")
        if autoSync { setAutoSync(true, for: added.id) }
        return nil
    }

    /// Moves a trashed repository folder back to where it was.
    func putBackFromTrash(_ id: UUID) async {
        guard let repo = repository(id), let trashed = runtime[id]?.trashedURL else { return }
        let original = URL(fileURLWithPath: repo.path)
        do {
            if FileManager.default.fileExists(atPath: original.path) {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: original.path])
            }
            try FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: trashed, to: original)
            adopt(id, folder: original, message: String(localized: "已将 \(repo.displayName) 从废纸篓放回 \(original.path)"))
            await refreshInfo(id)
        } catch {
            alert = AppAlert(title: String(localized: "无法放回原处"), message: error.localizedDescription)
        }
    }

    func refreshAllInfo() async {
        for repo in repositories {
            await refreshInfo(repo.id)
        }
        Task {
            for repo in repositories {
                await refreshUsage(repo.id)
            }
        }
    }

    // MARK: - Disk usage

    /// Measures the folder and its history, at most every 10 minutes unless forced. Warns when the
    /// history passes GitHub's recommended size (once per level per launch).
    /// `filesChanged: false` (a sync that changed nothing on disk) keeps the known file size and only
    /// re-reads the history size, which is cheap.
    func refreshUsage(_ id: UUID, force: Bool = false, filesChanged: Bool = true) async {
        guard let repo = repository(id), let git = gitEnvironment else { return }
        if !force, let last = runtime[id]?.usage?.measuredAt, Date().timeIntervalSince(last) < 600 { return }
        guard runtime[id]?.measuringUsage != true else { return }
        runtime[id, default: RepoRuntime()].measuringUsage = true
        defer { runtime[id]?.measuringUsage = false }

        let previous = runtime[id]?.usage?.level
        let scanner = RepositoryUsageScanner(client: GitClient(repositoryURL: URL(fileURLWithPath: repo.path), git: git))
        let knownFiles = filesChanged ? nil : runtime[id]?.usage?.fileBytes
        guard let usage = try? await scanner.measure(reusingFileBytes: knownFiles) else { return }
        runtime[id]?.usage = usage

        guard usage.level != .normal, usage.level != previous, previous != .veryLarge else { return }
        let size = ByteCountFormatter.string(fromByteCount: usage.historyBytes, countStyle: .file)
        let text = usage.level == .veryLarge
            ? String(localized: "历史已占用 \(size)，超过 GitHub 的 5 GB 警告线")
            : String(localized: "历史已占用 \(size)，超过 GitHub 建议的 1 GB")
        log(id, String(localized: "空间占用"), .warning, "\(repo.displayName)：\(text)")
        notifications.post(title: String(localized: "\(repo.displayName) 的仓库比较大"), body: text + String(localized: "。可在仓库卡片上查看最占空间的文件。"),
                           identifier: "size-\(id)")
    }

    // MARK: - Global auto sync

    func setInterval(minutes: Int) {
        settings.intervalMinutes = max(1, min(minutes, 24 * 60))
    }

    private func restartScheduler(runImmediately: Bool) {
        schedulerTask?.cancel()
        schedulerTask = nil
        guard !isShuttingDown else {
            nextSyncDate = nil
            return
        }
        if runImmediately {
            syncAll(trigger: .startup)
        }
        let interval = TimeInterval(settings.intervalMinutes * 60)
        schedulerTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.nextSyncDate = Date().addingTimeInterval(interval)
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self else { return }
                self.syncAll(trigger: .scheduled)
            }
        }
    }

    private func networkChanged(online: Bool) {
        guard online != isOnline else { return }
        isOnline = online
        log(nil, String(localized: "网络"), online ? .info : .warning, online ? String(localized: "网络已恢复") : String(localized: "网络已断开，自动同步将在网络恢复后继续"))
        guard online, autoSyncCount > 0 else { return }
        Task {
            try? await Task.sleep(for: .seconds(5))
            guard self.isOnline else { return }
            self.syncAll(trigger: .networkRestored)
            self.restartScheduler(runImmediately: false)
        }
    }

    private func handleWake() {
        log(nil, String(localized: "系统"), .info, String(localized: "系统已唤醒"))
        guard autoSyncCount > 0, settings.syncOnWake else { return }
        Task {
            // Give Wi-Fi time to reconnect.
            try? await Task.sleep(for: .seconds(10))
            self.syncAll(trigger: .wake)
            self.restartScheduler(runImmediately: false)
        }
    }

    // MARK: - Sync

    func syncAll(trigger: SyncTrigger) {
        let targets = repositories.filter { repo in
            if repo.pausedForConflict { return false }
            return trigger == .manualAll || repo.autoSyncEnabled
        }
        if trigger == .manualAll, targets.isEmpty, !repositories.isEmpty {
            alert = AppAlert(title: String(localized: "没有可同步的仓库"), message: String(localized: "所有仓库都因冲突暂停。请先处理冲突。"))
        }
        for repo in targets {
            sync(repo.id, trigger: trigger)
        }
    }

    func sync(_ id: UUID, trigger: SyncTrigger) {
        guard !isShuttingDown, repository(id) != nil else { return }
        if runtime[id]?.isSyncing != true, !followFolder(id), let missing = repository(id) {
            let inTrash = runtime[id]?.trashedURL != nil
            let failure = SyncFailure(
                kind: .folderMissing, stage: .inspect,
                message: inTrash ? String(localized: "文件夹在废纸篓中：\(missing.displayName)")
                                 : String(localized: "本地文件夹不存在或已被移动：\(missing.path)")
            )
            finish(id: id, report: nil, failure: failure, trigger: trigger)
            if !inTrash { Task { await findCandidates(id) } }
            return
        }
        guard let repo = repository(id) else { return }
        if runtime[id]?.isSyncing == true {
            if trigger.isManual {
                log(id, String(localized: "同步"), .info, String(localized: "\(repo.displayName) 正在同步中，已忽略重复请求"))
            }
            return
        }
        guard let git = gitEnvironment else {
            let failure = SyncFailure(kind: .gitUnavailable, stage: .preflight, stderr: gitProblem ?? "")
            finish(id: id, report: nil, failure: failure, trigger: trigger)
            return
        }
        guard isOnline else {
            update(id) {
                $0.lastStatus = .networkUnavailable
                $0.lastAttemptAt = Date()
                $0.lastMessage = String(localized: "网络不可用，等待网络恢复后自动重试")
            }
            if trigger.isManual {
                log(id, String(localized: "同步"), .warning, String(localized: "\(repo.displayName)：网络不可用，未执行同步"))
            }
            return
        }

        runtime[id, default: RepoRuntime()].isSyncing = true
        runtime[id]?.phase = nil
        let options = makeSyncOptions()
        let repoURL = URL(fileURLWithPath: repo.path)

        syncTasks[id] = Task {
            let credential = await auth.credentialForGit()
            let engine = SyncEngine(client: GitClient(repositoryURL: repoURL, git: git, credential: credential), options: options)
            let report = await coordinator.run(id: id) {
                await engine.sync { phase in
                    Task { @MainActor in AppModel.shared.updatePhase(id, phase) }
                }
            }
            if let report {
                finish(id: id, report: report, failure: nil, trigger: trigger)
            } else {
                runtime[id]?.isSyncing = false
            }
            syncTasks[id] = nil
        }
    }

    func resolveConflicts(_ id: UUID, choices: [String: ConflictChoice]) {
        guard let repo = repository(id), let git = gitEnvironment else { return }
        guard runtime[id]?.isSyncing != true else { return }
        runtime[id, default: RepoRuntime()].isSyncing = true
        let options = makeSyncOptions()
        let summary = choices.map { "\($0.key) → \($0.value.displayName)" }.sorted().joined(separator: "\n")
        log(id, String(localized: "解决冲突"), .info, String(localized: "开始按用户选择解决 \(repo.displayName) 的 \(choices.count) 个冲突"), detail: summary)

        syncTasks[id] = Task {
            let credential = await auth.credentialForGit()
            let engine = SyncEngine(client: GitClient(repositoryURL: URL(fileURLWithPath: repo.path), git: git, credential: credential), options: options)
            let report = await coordinator.run(id: id) {
                await engine.resolveConflicts(choices: choices) { phase in
                    Task { @MainActor in AppModel.shared.updatePhase(id, phase) }
                }
            }
            if let report {
                finish(id: id, report: report, failure: nil, trigger: .conflictResolution)
            } else {
                runtime[id]?.isSyncing = false
            }
            syncTasks[id] = nil
        }
    }

    /// Clears the conflict pause and runs a normal sync, which re-detects any remaining conflict.
    func recheckAndResume(_ id: UUID) {
        update(id) { $0.pausedForConflict = false }
        sync(id, trigger: .manualSingle)
    }

    func exportRemoteVersion(_ id: UUID, path: String) async {
        guard let repo = repository(id), let git = gitEnvironment else { return }
        let engine = SyncEngine(client: GitClient(repositoryURL: URL(fileURLWithPath: repo.path), git: git), options: makeSyncOptions())
        do {
            let url = try await engine.exportRemoteVersion(of: path)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch let failure as SyncFailure {
            alert = AppAlert(title: String(localized: "无法导出远程版本"), message: failure.message + "\n\n" + failure.stderr)
        } catch {
            alert = AppAlert(title: String(localized: "无法导出远程版本"), message: error.localizedDescription)
        }
    }

    // MARK: - History

    /// Read-only access to a repository's history; nil when Git is unavailable.
    func historyBrowser(_ id: UUID) -> HistoryBrowser? {
        guard let repo = repository(id), let git = gitEnvironment else { return nil }
        return HistoryBrowser(client: GitClient(repositoryURL: URL(fileURLWithPath: repo.path), git: git))
    }

    /// Brings a file or the whole folder back to a committed version, then syncs the result.
    func restore(_ id: UUID, target: RestoreTarget, description: String) {
        guard let repo = repository(id) else { return }
        runRestore(id, logTitle: String(localized: "恢复历史版本"),
                   logMessage: String(localized: "开始恢复 \(repo.displayName)：\(description)")) { engine, progress in
            await engine.restore(target, description: description, progress: progress)
        }
    }

    /// Puts files or folders back to their current GitHub version, discarding local changes that
    /// were not synced yet (a backup of them stays on this Mac).
    func revertToCloud(_ id: UUID, paths: [String]) {
        guard let repo = repository(id), !paths.isEmpty else { return }
        let names = paths.prefix(3).joined(separator: String(localized: "、")) + (paths.count > 3 ? String(localized: " 等 \(paths.count) 项") : "")
        runRestore(id, logTitle: String(localized: "还原为云端版本"),
                   logMessage: String(localized: "开始将 \(repo.displayName) 中的 \(names) 还原为 GitHub 上的版本")) { engine, progress in
            await engine.revertToRemote(paths: paths, progress: progress)
        }
    }

    /// Local changes not synced yet, as `git status` reports them.
    func pendingChanges(_ id: UUID) async -> [StatusEntry] {
        guard let repo = repository(id), let git = gitEnvironment else { return [] }
        let client = GitClient(repositoryURL: URL(fileURLWithPath: repo.path), git: git)
        guard let result = try? await client.run(["status", "--porcelain=v1", "-z", "--untracked-files=all"], timeout: 60),
              result.succeeded else { return [] }
        return StatusEntry.parse(result.stdoutData).sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func runRestore(_ id: UUID, logTitle: String, logMessage: String,
                            operation: @escaping @Sendable (SyncEngine, @escaping @Sendable (SyncPhase) -> Void) async -> SyncReport) {
        guard !isShuttingDown, let repo = repository(id), let git = gitEnvironment else { return }
        guard runtime[id]?.isSyncing != true else {
            alert = AppAlert(title: String(localized: "请稍候"), message: String(localized: "\(repo.displayName) 正在同步，完成后再恢复。"))
            return
        }
        runtime[id, default: RepoRuntime()].isSyncing = true
        runtime[id]?.phase = nil
        let options = makeSyncOptions()
        log(id, logTitle, .info, logMessage)

        syncTasks[id] = Task {
            let credential = await auth.credentialForGit()
            let engine = SyncEngine(client: GitClient(repositoryURL: URL(fileURLWithPath: repo.path), git: git, credential: credential), options: options)
            let report = await coordinator.run(id: id) {
                await operation(engine) { phase in
                    Task { @MainActor in AppModel.shared.updatePhase(id, phase) }
                }
            }
            if let report {
                finish(id: id, report: report, failure: nil, trigger: .restore)
            } else {
                runtime[id]?.isSyncing = false
            }
            syncTasks[id] = nil
        }
    }

    /// Saves an old version next to the current file and shows it in Finder. Returns false on failure.
    @discardableResult
    func saveVersionCopy(_ id: UUID, path: String, commit: String, date: Date, besides currentPath: String? = nil) async -> Bool {
        guard let browser = historyBrowser(id) else { return false }
        do {
            let copy = try await browser.saveCopy(path: path, commit: commit, date: date, besides: currentPath)
            log(id, String(localized: "历史版本"), .success, String(localized: "已将「\(path)」的历史版本另存为「\(copy)」，下次同步时上传"))
            revealInFinder(id, relativePath: copy)
            return true
        } catch {
            alert = AppAlert(title: String(localized: "无法另存副本"), message: (error as? SyncFailure)?.fullReport ?? error.localizedDescription)
            return false
        }
    }

    func abortInProgressOperation(_ id: UUID) async {
        guard let repo = repository(id), let git = gitEnvironment, runtime[id]?.isSyncing != true else { return }
        let engine = SyncEngine(client: GitClient(repositoryURL: URL(fileURLWithPath: repo.path), git: git), options: makeSyncOptions())
        do {
            if let operation = try await engine.abortInProgressOperation() {
                log(id, String(localized: "中止操作"), .warning, String(localized: "已按用户确认中止 \(repo.displayName) 中未完成的\(operation.displayName)"))
                update(id) {
                    $0.lastStatus = .notSynced
                    $0.lastFailure = nil
                    $0.lastMessage = String(localized: "已中止\(operation.displayName)")
                }
            }
        } catch let failure as SyncFailure {
            log(id, String(localized: "中止操作"), .error, failure.message, exitCode: failure.exitCode, detail: failure.fullReport)
            alert = AppAlert(title: String(localized: "中止失败"), message: failure.fullReport)
        } catch {
            alert = AppAlert(title: String(localized: "中止失败"), message: error.localizedDescription)
        }
        await refreshInfo(id)
    }

    private func updatePhase(_ id: UUID, _ phase: SyncPhase) {
        guard runtime[id]?.isSyncing == true else { return }
        runtime[id]?.phase = phase
    }

    private func finish(id: UUID, report: SyncReport?, failure: SyncFailure?, trigger: SyncTrigger) {
        runtime[id, default: RepoRuntime()].isSyncing = false
        runtime[id]?.phase = nil
        guard let repo = repository(id) else { return }   // removed while syncing
        let previousStatus = repo.lastStatus
        let previousFailureKind = repo.lastFailure?.kind

        if let report {
            if let info = report.info { runtime[id]?.info = info }
            runtime[id]?.warnings = report.warnings
            runtime[id]?.lastSteps = report.steps
        }
        let stepsText = report?.steps.map(\.line).joined(separator: "\n") ?? ""
        let warningsText = report?.warnings.joined(separator: "\n") ?? ""
        let duration = report?.duration
        let now = Date()

        let outcome: SyncReport.Outcome = report?.outcome ?? .failure(failure ?? SyncFailure(kind: .unknown, stage: .preflight))
        switch outcome {
        case .success(let summary):
            let filesChanged = summary.committedFiles > 0 || summary.downloadedCommits > 0 || summary.restoredFiles > 0
            Task {
                await refreshUsage(id, filesChanged: filesChanged)
                await followRemoteRename(id)
            }
            update(id) {
                $0.lastStatus = .success
                $0.lastSyncAt = now
                $0.lastAttemptAt = now
                $0.lastMessage = summary.text
                $0.lastFailure = nil
                $0.conflictFiles = []
                $0.pausedForConflict = false
            }
            log(id, trigger.displayName, .success, (trigger == .restore ? String(localized: "\(repo.displayName)：恢复完成，\(summary.text)") : String(localized: "\(repo.displayName)：同步成功，\(summary.text)")),
                detail: join(warningsText, stepsText), duration: duration)
            if settings.notifyOnChanges, summary.downloadedCommits > 0 || summary.uploadedCommits > 0 {
                notifications.post(title: String(localized: "\(repo.displayName) 已同步"), body: summary.text, identifier: "sync-\(id)")
            }
            if let downloaded = report?.downloadedFiles, !downloaded.isEmpty {
                refreshOpenDocuments(id, relativePaths: downloaded)
            }
        case .noChanges:
            Task { await followRemoteRename(id) }
            update(id) {
                $0.lastStatus = .noChanges
                $0.lastSyncAt = now
                $0.lastAttemptAt = now
                $0.lastMessage = String(localized: "本地与 GitHub 均无变化")
                $0.lastFailure = nil
                $0.pausedForConflict = false
                $0.conflictFiles = []
            }
            log(id, trigger.displayName, .info, String(localized: "\(repo.displayName)：无文件变化"),
                detail: join(warningsText, stepsText), duration: duration)
        case .conflict(let files):
            update(id) {
                $0.lastStatus = .conflict
                $0.lastAttemptAt = now
                $0.lastMessage = String(localized: "\(files.count) 个文件在本地和 GitHub 上都被修改")
                $0.conflictFiles = files
                $0.pausedForConflict = true
                $0.lastFailure = nil
            }
            let list = files.map { "• \($0.path)：\($0.description)" }.joined(separator: "\n")
            log(id, String(localized: "整合远程更新"), .error, String(localized: "\(repo.displayName)：检测到 \(files.count) 个冲突文件，已暂停该仓库自动同步（没有覆盖任何文件）"),
                detail: join(list, stepsText), duration: duration)
            if settings.notifyOnConflict, previousStatus != .conflict {
                notifications.post(title: String(localized: "\(repo.displayName) 存在同步冲突"),
                                   body: String(localized: "\(files.count) 个文件需要你选择保留哪个版本。已暂停该仓库的自动同步。"),
                                   identifier: "conflict-\(id)")
            }
        case .failure(let failure):
            update(id) {
                $0.lastStatus = failure.mappedStatus
                $0.lastAttemptAt = now
                $0.lastMessage = failure.message
                $0.lastFailure = failure
            }
            log(id, failure.stage.displayName, failure.kind == .network ? .warning : .error,
                "\(repo.displayName)：\(failure.message)", exitCode: failure.exitCode,
                detail: join(failure.fullReport, warningsText, String(localized: "执行记录：\n") + stepsText), duration: duration)

            let changed = previousStatus != failure.mappedStatus || previousFailureKind != failure.kind
            if failure.mappedStatus == .needsAuth {
                auth.handleGitAuthFailure()
                if settings.notifyOnAuthProblem, changed {
                    notifications.post(title: String(localized: "GitHub 认证失败"), body: String(localized: "\(repo.displayName)：\(failure.message)。请在设置中重新登录。"),
                                       identifier: "auth-\(id)")
                }
            } else if failure.mappedStatus != .networkUnavailable, settings.notifyOnFailure, changed {
                notifications.post(title: String(localized: "\(repo.displayName) 同步失败"), body: failure.message, identifier: "failure-\(id)")
            }
        }
    }

    private func makeSyncOptions() -> SyncOptions {
        var options = SyncOptions()
        options.ignorePatterns = settings.ignorePatterns
        options.largeFileLimitBytes = Int64(max(1, settings.largeFileLimitMB)) * 1024 * 1024
        options.largeFileWarningBytes = min(options.largeFileWarningBytes, options.largeFileLimitBytes / 2)
        options.machineName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        if let identity = auth.identity { options.fallbackIdentity = identity }
        return options
    }

    // MARK: - Finder / GitHub

    func revealInFinder(_ id: UUID, relativePath: String? = nil) {
        guard let repo = repository(id) else { return }
        var url = URL(fileURLWithPath: repo.path)
        if let relativePath { url.appendPathComponent(relativePath) }
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else if FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        } else {
            alert = AppAlert(title: String(localized: "文件夹不存在"), message: String(localized: "找不到 \(url.path)，它可能已被移动或删除。"))
        }
    }

    func openOnGitHub(_ id: UUID) {
        guard let url = runtime[id]?.info?.webURL else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Persistence & logging

    private func settingsDidChange(from old: AppSettings) {
        guard !isRestoring else { return }
        persist()
        if old.intervalMinutes != settings.intervalMinutes {
            log(nil, String(localized: "自动同步"), .info, String(localized: "同步间隔已改为 \(settings.intervalMinutes) 分钟"))
            restartScheduler(runImmediately: false)
        }
        if old.maxConcurrentSyncs != settings.maxConcurrentSyncs {
            let value = settings.maxConcurrentSyncs
            Task { await coordinator.setMaxConcurrent(value) }
        }
        if old.showDockIcon != settings.showDockIcon {
            applyDockPolicy()
        }
        if old.customGitPath != settings.customGitPath {
            Task { await detectGit() }
        }
    }

    func applyDockPolicy() {
        NSApp?.setActivationPolicy(settings.showDockIcon ? .regular : .accessory)
    }

    private func update(_ id: UUID, _ change: (inout RepositoryConfig) -> Void) {
        guard let index = repositories.firstIndex(where: { $0.id == id }) else { return }
        change(&repositories[index])
        persist()
    }

    func persist() {
        do {
            try store.save(PersistedState(settings: settings, repositories: repositories))
        } catch {
            logStore.add(SyncLogEntry(repositoryName: "GitSync", stage: String(localized: "配置"), level: .error,
                                      result: String(localized: "保存配置失败"), detail: error.localizedDescription))
        }
    }

    var stateFileURL: URL { store.url }

    func log(
        _ repoID: UUID?, _ stage: String, _ level: LogLevel, _ result: String,
        exitCode: Int32? = nil, detail: String? = nil, duration: TimeInterval? = nil
    ) {
        let name = repoID.flatMap { repository($0)?.displayName } ?? "GitSync"
        logStore.add(SyncLogEntry(repositoryID: repoID, repositoryName: name, stage: stage, level: level,
                                  result: result, exitCode: exitCode, detail: detail, duration: duration))
    }

    private func logAuthState() {
        let level: LogLevel = auth.state.isUsable ? .info : .warning
        log(nil, String(localized: "GitHub 认证"), level, auth.state.summary)
    }

    private func join(_ parts: String...) -> String {
        parts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n\n")
    }

    // MARK: - Overall status

    var syncingCount: Int { runtime.values.filter(\.isSyncing).count }

    var overallStatusText: String {
        if gitEnvironment == nil, gitProblem != nil { return String(localized: "未找到 Git") }
        if !isOnline { return String(localized: "网络不可用") }
        if syncingCount > 0 { return String(localized: "\(syncingCount) 个仓库正在同步") }
        let problems = repositories.filter { $0.lastStatus.isProblem }.count
        if problems > 0 { return String(localized: "\(problems) 个仓库需要处理") }
        let count = autoSyncCount
        return count > 0 ? String(localized: "\(count) 个仓库自动同步中") : String(localized: "自动同步已全部关闭")
    }

    /// The symbol in the badge of the menu bar icon (the cat from the app icon plus this badge).
    var menuBarBadge: String {
        if syncingCount > 0 { return "ellipsis" }
        if repositories.contains(where: { $0.lastStatus == .conflict || $0.lastStatus == .needsAuth || $0.lastStatus == .failed }) {
            return "exclamationmark"
        }
        if !isOnline { return "wifi.slash" }
        return autoSyncCount > 0 ? "arrow.triangle.2.circlepath" : "pause.fill"
    }
}
