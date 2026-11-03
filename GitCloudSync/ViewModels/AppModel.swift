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
}

enum SyncTrigger: String {
    case manualSingle, manualAll, scheduled, startup, wake, networkRestored, conflictResolution

    var isManual: Bool { self == .manualSingle || self == .manualAll || self == .conflictResolution }

    var displayName: String {
        switch self {
        case .manualSingle, .manualAll: "手动同步"
        case .scheduled: "定时同步"
        case .startup: "启动同步"
        case .wake: "唤醒后同步"
        case .networkRestored: "网络恢复后同步"
        case .conflictResolution: "解决冲突"
        }
    }
}

enum AppSheet: Identifiable {
    case errorDetail(UUID)
    case conflicts(UUID)
    case deviceFlow

    var id: String {
        switch self {
        case .errorDetail(let id): "error-\(id)"
        case .conflicts(let id): "conflict-\(id)"
        case .deviceFlow: "device-flow"
        }
    }
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
    var alert: AppAlert?

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
        settings = loaded.settings
        repositories = loaded.repositories
        coordinator = SyncCoordinator(maxConcurrent: loaded.settings.maxConcurrentSyncs)
        isRestoring = false
        if let loadError {
            log(nil, "配置", .error, "读取配置失败，已备份旧文件并使用默认配置", detail: loadError)
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        applyDockPolicy()
        notifications.requestAuthorization()
        log(nil, "启动", .info, "GitSync 已启动，管理 \(repositories.count) 个仓库")

        networkMonitor.start { online in
            Task { @MainActor in AppModel.shared.networkChanged(online: online) }
        }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in AppModel.shared.handleWake() }
        }
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in AppModel.shared.log(nil, "系统", .info, "系统即将休眠") }
        }

        Task {
            await detectGit()
            await auth.refresh()
            logAuthState()
            await refreshAllInfo()
            if settings.autoSyncEnabled {
                log(nil, "自动同步", .info, "恢复上次的自动同步状态（每 \(settings.intervalMinutes) 分钟）")
                restartScheduler(runImmediately: true)
            }
        }
    }

    func detectGit() async {
        switch await GitEnvironment.detect(customPath: settings.customGitPath) {
        case .success(let env):
            gitEnvironment = env
            gitProblem = nil
            auth.gitEnvironment = env
            log(nil, "环境", .info, "使用 \(env.gitURL.path)（\(env.version)）")
        case .failure(let error):
            gitEnvironment = nil
            gitProblem = error.localizedDescription
            log(nil, "环境", .error, "未找到可用的 Git", detail: error.localizedDescription)
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
            log(nil, "退出", .info, "等待 \(syncTasks.count) 个正在进行的同步完成…")
        }
        while !syncTasks.isEmpty, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
        if !syncTasks.isEmpty {
            log(nil, "退出", .warning, "仍有同步未完成，Git 进程将独立运行至结束；下次启动会重新检查仓库状态")
        }
        persist()
        logStore.flush()
    }

    // MARK: - Repositories

    func addRepositories(urls: [URL]) async {
        guard let git = gitEnvironment else {
            alert = AppAlert(title: "无法添加仓库", message: gitProblem ?? "未找到 Git")
            return
        }
        var problems: [String] = []
        for url in urls {
            let client = GitClient(repositoryURL: url, git: git)
            do {
                let info = try await RepositoryInspector(client: client).inspect()
                if repositories.contains(where: { $0.path == info.topLevelPath }) {
                    problems.append("「\(url.lastPathComponent)」已经在列表中。")
                    continue
                }
                let config = RepositoryConfig(
                    path: info.topLevelPath,
                    displayName: URL(fileURLWithPath: info.topLevelPath).lastPathComponent
                )
                repositories.append(config)
                runtime[config.id, default: RepoRuntime()].info = info
                var detail = "路径：\(info.topLevelPath)\n分支：\(info.branch ?? "（分离 HEAD）")\n远程：\(info.remoteURL ?? "未配置")"
                detail += "\n未提交修改：\(info.changedFiles) 个，领先 \(info.ahead)，落后 \(info.behind)"
                log(config.id, "添加仓库", .success, "已添加仓库 \(config.displayName)", detail: detail)
                if info.topLevelPath != url.standardizedFileURL.path && info.topLevelPath != url.resolvingSymlinksInPath().path {
                    problems.append("「\(url.lastPathComponent)」位于仓库内部，已改为添加仓库根目录：\(info.topLevelPath)")
                }
                if info.remoteURL == nil {
                    problems.append("「\(config.displayName)」没有配置远程 origin，请先在 GitHub Desktop 中发布（Publish）后再同步。")
                } else if !info.isGitHubRemote {
                    problems.append("「\(config.displayName)」的远程不是 GitHub（\(info.remoteURL ?? "")），将使用系统凭据进行同步。")
                }
                if let op = info.inProgressOperation {
                    problems.append("「\(config.displayName)」有未完成的\(op.displayName)，需要先处理才能同步。")
                }
            } catch let failure as SyncFailure {
                problems.append("「\(url.lastPathComponent)」：\(failure.message)\n\(failure.suggestion)")
            } catch {
                problems.append("「\(url.lastPathComponent)」：\(error.localizedDescription)")
            }
        }
        persist()
        if !problems.isEmpty {
            alert = AppAlert(title: "添加仓库", message: problems.joined(separator: "\n\n"))
        }
    }

    /// Removes the repository from the list only. Files and the GitHub repository are untouched.
    func removeRepository(_ id: UUID) {
        guard let repo = repository(id) else { return }
        repositories.removeAll { $0.id == id }
        runtime[id] = nil
        log(nil, "移除仓库", .info, "已从列表移除 \(repo.displayName)（本地文件与 GitHub 仓库均未改动）")
        persist()
    }

    func setAutoSync(_ enabled: Bool, for id: UUID) {
        update(id) { $0.autoSyncEnabled = enabled }
        if let repo = repository(id) {
            log(id, "设置", .info, "\(repo.displayName) 自动同步已\(enabled ? "开启" : "暂停")")
        }
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
        guard let git = gitEnvironment, let repo = repository(id) else { return }
        let client = GitClient(repositoryURL: URL(fileURLWithPath: repo.path), git: git)
        do {
            let info = try await RepositoryInspector(client: client).inspect()
            runtime[id, default: RepoRuntime()].info = info
        } catch let failure as SyncFailure {
            runtime[id, default: RepoRuntime()].info = nil
            if failure.kind == .folderMissing || failure.kind == .notARepository || failure.kind == .permissionDenied {
                update(id) {
                    $0.lastStatus = .failed
                    $0.lastFailure = failure
                    $0.lastMessage = failure.message
                }
            }
        } catch {}
    }

    func refreshAllInfo() async {
        for repo in repositories {
            await refreshInfo(repo.id)
        }
    }

    // MARK: - Global auto sync

    func startAutoSync() {
        settings.autoSyncEnabled = true   // didSet restarts the scheduler
    }

    func pauseAutoSync() {
        settings.autoSyncEnabled = false
    }

    func setInterval(minutes: Int) {
        settings.intervalMinutes = max(1, min(minutes, 24 * 60))
    }

    private func restartScheduler(runImmediately: Bool) {
        schedulerTask?.cancel()
        schedulerTask = nil
        guard settings.autoSyncEnabled, !isShuttingDown else {
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
        log(nil, "网络", online ? .info : .warning, online ? "网络已恢复" : "网络已断开，自动同步将在网络恢复后继续")
        guard online, settings.autoSyncEnabled else { return }
        Task {
            try? await Task.sleep(for: .seconds(5))
            guard self.isOnline else { return }
            self.syncAll(trigger: .networkRestored)
            self.restartScheduler(runImmediately: false)
        }
    }

    private func handleWake() {
        log(nil, "系统", .info, "系统已唤醒")
        guard settings.autoSyncEnabled, settings.syncOnWake else { return }
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
            alert = AppAlert(title: "没有可同步的仓库", message: "所有仓库都因冲突暂停。请先处理冲突。")
        }
        for repo in targets {
            sync(repo.id, trigger: trigger)
        }
    }

    func sync(_ id: UUID, trigger: SyncTrigger) {
        guard !isShuttingDown, let repo = repository(id) else { return }
        if runtime[id]?.isSyncing == true {
            if trigger.isManual {
                log(id, "同步", .info, "\(repo.displayName) 正在同步中，已忽略重复请求")
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
                $0.lastMessage = "网络不可用，等待网络恢复后自动重试"
            }
            if trigger.isManual {
                log(id, "同步", .warning, "\(repo.displayName)：网络不可用，未执行同步")
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
        log(id, "解决冲突", .info, "开始按用户选择解决 \(repo.displayName) 的 \(choices.count) 个冲突", detail: summary)

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
            alert = AppAlert(title: "无法导出远程版本", message: failure.message + "\n\n" + failure.stderr)
        } catch {
            alert = AppAlert(title: "无法导出远程版本", message: error.localizedDescription)
        }
    }

    func abortInProgressOperation(_ id: UUID) async {
        guard let repo = repository(id), let git = gitEnvironment, runtime[id]?.isSyncing != true else { return }
        let engine = SyncEngine(client: GitClient(repositoryURL: URL(fileURLWithPath: repo.path), git: git), options: makeSyncOptions())
        do {
            if let operation = try await engine.abortInProgressOperation() {
                log(id, "中止操作", .warning, "已按用户确认中止 \(repo.displayName) 中未完成的\(operation.displayName)")
                update(id) {
                    $0.lastStatus = .notSynced
                    $0.lastFailure = nil
                    $0.lastMessage = "已中止\(operation.displayName)"
                }
            }
        } catch let failure as SyncFailure {
            log(id, "中止操作", .error, failure.message, exitCode: failure.exitCode, detail: failure.fullReport)
            alert = AppAlert(title: "中止失败", message: failure.fullReport)
        } catch {
            alert = AppAlert(title: "中止失败", message: error.localizedDescription)
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
            update(id) {
                $0.lastStatus = .success
                $0.lastSyncAt = now
                $0.lastAttemptAt = now
                $0.lastMessage = summary.text
                $0.lastFailure = nil
                $0.conflictFiles = []
                $0.pausedForConflict = false
            }
            log(id, trigger.displayName, .success, "\(repo.displayName)：同步成功，\(summary.text)",
                detail: join(warningsText, stepsText), duration: duration)
            if settings.notifyOnChanges, summary.downloadedCommits > 0 || summary.uploadedCommits > 0 {
                notifications.post(title: "\(repo.displayName) 已同步", body: summary.text, identifier: "sync-\(id)")
            }
        case .noChanges:
            update(id) {
                $0.lastStatus = .noChanges
                $0.lastSyncAt = now
                $0.lastAttemptAt = now
                $0.lastMessage = "本地与 GitHub 均无变化"
                $0.lastFailure = nil
                $0.pausedForConflict = false
                $0.conflictFiles = []
            }
            log(id, trigger.displayName, .info, "\(repo.displayName)：无文件变化",
                detail: join(warningsText, stepsText), duration: duration)
        case .conflict(let files):
            update(id) {
                $0.lastStatus = .conflict
                $0.lastAttemptAt = now
                $0.lastMessage = "\(files.count) 个文件在本地和 GitHub 上都被修改"
                $0.conflictFiles = files
                $0.pausedForConflict = true
                $0.lastFailure = nil
            }
            let list = files.map { "• \($0.path)：\($0.description)" }.joined(separator: "\n")
            log(id, "整合远程更新", .error, "\(repo.displayName)：检测到 \(files.count) 个冲突文件，已暂停该仓库自动同步（没有覆盖任何文件）",
                detail: join(list, stepsText), duration: duration)
            if settings.notifyOnConflict, previousStatus != .conflict {
                notifications.post(title: "\(repo.displayName) 存在同步冲突",
                                   body: "\(files.count) 个文件需要你选择保留哪个版本。已暂停该仓库的自动同步。",
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
                detail: join(failure.fullReport, warningsText, "执行记录：\n" + stepsText), duration: duration)

            let changed = previousStatus != failure.mappedStatus || previousFailureKind != failure.kind
            if failure.mappedStatus == .needsAuth {
                auth.handleGitAuthFailure()
                if settings.notifyOnAuthProblem, changed {
                    notifications.post(title: "GitHub 认证失败", body: "\(repo.displayName)：\(failure.message)。请在设置中重新登录。",
                                       identifier: "auth-\(id)")
                }
            } else if failure.mappedStatus != .networkUnavailable, settings.notifyOnFailure, changed {
                notifications.post(title: "\(repo.displayName) 同步失败", body: failure.message, identifier: "failure-\(id)")
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

    // MARK: - Finder / Terminal / GitHub

    func revealInFinder(_ id: UUID, relativePath: String? = nil) {
        guard let repo = repository(id) else { return }
        var url = URL(fileURLWithPath: repo.path)
        if let relativePath { url.appendPathComponent(relativePath) }
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else if FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        } else {
            alert = AppAlert(title: "文件夹不存在", message: "找不到 \(url.path)，它可能已被移动或删除。")
        }
    }

    func openInTerminal(_ id: UUID) {
        guard let repo = repository(id),
              let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([URL(fileURLWithPath: repo.path)], withApplicationAt: terminal,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    func openOnGitHub(_ id: UUID) {
        guard let url = runtime[id]?.info?.webURL else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Persistence & logging

    private func settingsDidChange(from old: AppSettings) {
        guard !isRestoring else { return }
        persist()
        if old.autoSyncEnabled != settings.autoSyncEnabled {
            log(nil, "自动同步", .info, settings.autoSyncEnabled
                ? "已启动自动同步（每 \(settings.intervalMinutes) 分钟）" : "已暂停自动同步")
            restartScheduler(runImmediately: settings.autoSyncEnabled)
        } else if old.intervalMinutes != settings.intervalMinutes {
            log(nil, "自动同步", .info, "同步间隔已改为 \(settings.intervalMinutes) 分钟")
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
            logStore.add(SyncLogEntry(repositoryName: "GitSync", stage: "配置", level: .error,
                                      result: "保存配置失败", detail: error.localizedDescription))
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
        log(nil, "GitHub 认证", level, auth.state.summary)
    }

    private func join(_ parts: String...) -> String {
        parts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n\n")
    }

    // MARK: - Overall status

    var syncingCount: Int { runtime.values.filter(\.isSyncing).count }

    var overallStatusText: String {
        if gitEnvironment == nil, gitProblem != nil { return "未找到 Git" }
        if !isOnline { return "网络不可用" }
        if syncingCount > 0 { return "\(syncingCount) 个仓库正在同步" }
        let problems = repositories.filter { $0.lastStatus.isProblem }.count
        if problems > 0 { return "\(problems) 个仓库需要处理" }
        return settings.autoSyncEnabled ? "自动同步运行中" : "自动同步已暂停"
    }

    var menuBarSymbol: String {
        if syncingCount > 0 { return "arrow.triangle.2.circlepath.icloud" }
        if repositories.contains(where: { $0.lastStatus == .conflict || $0.lastStatus == .needsAuth || $0.lastStatus == .failed }) {
            return "exclamationmark.icloud"
        }
        if !isOnline { return "icloud.slash" }
        return settings.autoSyncEnabled ? "checkmark.icloud" : "icloud"
    }
}
