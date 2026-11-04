import Foundation

public struct GitIdentity: Sendable, Equatable {
    public var name: String
    public var email: String

    public init(name: String, email: String) {
        self.name = name
        self.email = email
    }
}

public struct SyncOptions: Sendable {
    public var largeFileLimitBytes: Int64 = 100 * 1024 * 1024
    public var largeFileWarningBytes: Int64 = 50 * 1024 * 1024
    public var ignorePatterns: [String] = IgnoreRules.defaultPatterns
    public var machineName: String = ProcessInfo.processInfo.hostName
    /// Used only when the repository has no user.name / user.email configured.
    public var fallbackIdentity = GitIdentity(name: "GitSync", email: "gitsync@users.noreply.github.com")
    public var networkTimeout: TimeInterval = 300
    public var localTimeout: TimeInterval = 120
    public var maxPushRetries = 2

    public init() {}
}

/// What a restore brings back from history.
public enum RestoreTarget: Sendable, Hashable {
    /// One file back to a committed version. `sourcePath` is its name in that commit (it differs
    /// after a rename); the content is written to `path`, today's name.
    case file(path: String, sourcePath: String, commit: String)
    /// Every tracked file back to the state recorded in `commit`.
    case repository(commit: String)

    public var commit: String {
        switch self {
        case .file(_, _, let commit), .repository(let commit): commit
        }
    }
}

/// Thrown internally when a merge produced conflicts and was safely aborted.
struct ConflictDetected: Error {
    let files: [ConflictFile]
}

/// Collects step records and warnings for one run.
private final class SyncSession {
    var steps: [SyncStepRecord] = []
    var warnings: [String] = []

    func record(_ result: ProcessResult, stage: SyncStage, command: String) {
        var output = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if output.isEmpty { output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
        steps.append(SyncStepRecord(
            stage: stage,
            command: command,
            exitCode: result.exitCode,
            duration: result.duration,
            timedOut: result.timedOut,
            output: String(output.prefix(2000))
        ))
    }
}

/// The two-way sync state machine for one repository. See Docs/Architecture.md.
///
/// Safety rules enforced here:
/// * local changes are committed before anything from the remote is integrated;
/// * a conflicting merge is aborted immediately, leaving the local version on disk;
/// * no force-push, `reset --hard`, `clean` or checkout of the whole tree, ever.
public struct SyncEngine: Sendable {
    public let client: GitClient
    public let options: SyncOptions

    private var inspector: RepositoryInspector { RepositoryInspector(client: client) }
    private var repoURL: URL { client.repositoryURL }

    public init(client: GitClient, options: SyncOptions = SyncOptions()) {
        self.client = client
        self.options = options
    }

    // MARK: - Public entry points

    public func sync(progress: @escaping @Sendable (SyncPhase) -> Void = { _ in }) async -> SyncReport {
        await runReporting { session in
            try await performSync(session: session, progress: progress)
        }
    }

    /// Re-runs the merge and applies the user's per-file choices.
    public func resolveConflicts(
        choices: [String: ConflictChoice],
        progress: @escaping @Sendable (SyncPhase) -> Void = { _ in }
    ) async -> SyncReport {
        await runReporting { session in
            try await performResolution(choices: choices, session: session, progress: progress)
        }
    }

    /// Brings a file or the whole folder back to a committed version.
    ///
    /// Nothing is rewritten: current local edits are committed first, a backup ref is created,
    /// and the old content is recorded as a new commit that syncs like any other change. A
    /// restore can therefore itself be undone from the history.
    public func restore(
        _ target: RestoreTarget,
        description: String,
        progress: @escaping @Sendable (SyncPhase) -> Void = { _ in }
    ) async -> SyncReport {
        await runReporting { session in
            try await performRestore(target, description: description, session: session, progress: progress)
        }
    }

    /// Writes the remote version of a conflicting file to a temporary folder so the user can
    /// compare it with the local one. Nothing in the repository changes.
    public func exportRemoteVersion(of path: String) async throws -> URL {
        let info = try await inspector.inspect()
        guard let upstream = try await inspector.resolveUpstream(branch: info.branch) else {
            throw SyncFailure(kind: .unknown, stage: .conflictResolution, message: String(localized: "找不到远程分支，无法导出远程版本"))
        }
        let result = try await client.run(["show", "\(upstream):\(path)"], timeout: options.localTimeout)
        guard result.succeeded else {
            throw SyncFailure.from(result, stage: .conflictResolution, command: "git show \(upstream):\(path)")
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitSync-Compare", isDirectory: true)
            .appendingPathComponent(Self.timestamp(), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(Self.copyName(for: (path as NSString).lastPathComponent, label: String(localized: "远程版本")))
        try result.stdoutData.write(to: target)
        return target
    }

    /// Aborts a merge / rebase / cherry-pick that is in progress. Only call after the user
    /// explicitly confirmed; it discards resolution work for that operation.
    public func abortInProgressOperation() async throws -> InProgressOperation? {
        let info = try await inspector.inspect()
        guard let operation = info.inProgressOperation else { return nil }
        let args: [String] = switch operation {
        case .merge: ["merge", "--abort"]
        case .rebase: ["rebase", "--abort"]
        case .cherryPick: ["cherry-pick", "--abort"]
        case .revert: ["revert", "--abort"]
        }
        let result = try await client.run(args, timeout: options.localTimeout)
        guard result.succeeded else {
            throw SyncFailure.from(result, stage: .preflight, command: "git " + args.joined(separator: " "))
        }
        return operation
    }

    // MARK: - Driver

    private func runReporting(
        _ body: (SyncSession) async throws -> SyncReport.Outcome
    ) async -> SyncReport {
        let session = SyncSession()
        let start = Date()
        let outcome: SyncReport.Outcome
        do {
            outcome = try await body(session)
        } catch let conflict as ConflictDetected {
            outcome = .conflict(conflict.files)
        } catch let failure as SyncFailure {
            outcome = .failure(failure)
        } catch {
            outcome = .failure(SyncFailure(kind: .unknown, stage: .preflight, stderr: error.localizedDescription))
        }
        let info = try? await inspector.inspect()
        return SyncReport(
            outcome: outcome,
            steps: session.steps,
            warnings: session.warnings,
            info: info,
            startedAt: start,
            duration: Date().timeIntervalSince(start)
        )
    }

    private func performSync(
        session: SyncSession,
        progress: @Sendable (SyncPhase) -> Void
    ) async throws -> SyncReport.Outcome {
        progress(.checking)
        let info = try await preflight()
        guard let branch = info.branch else {
            throw SyncFailure(kind: .detachedHead, stage: .preflight)
        }

        progress(.downloading)
        try await fetch(session: session)

        let upstream = try await inspector.resolveUpstream(branch: branch)
        if info.isUnborn, upstream != nil {
            throw SyncFailure(kind: .unbornWithRemote, stage: .preflight)
        }

        progress(.committing)
        let committed = try await commitLocalChanges(session: session)

        let (downloaded, uploaded) = try await integrateAndPush(branch: branch, upstream: upstream, session: session, progress: progress)

        if committed == 0, downloaded == 0, uploaded == 0 {
            return .noChanges
        }
        return .success(SyncSummary(committedFiles: committed, downloadedCommits: downloaded, uploadedCommits: uploaded))
    }

    /// Merges what is on GitHub and pushes, retrying when another Mac pushed in between.
    /// Expects a fresh fetch; returns the number of commits downloaded and uploaded.
    private func integrateAndPush(
        branch: String,
        upstream initialUpstream: String?,
        session: SyncSession,
        progress: @Sendable (SyncPhase) -> Void
    ) async throws -> (downloaded: Int, uploaded: Int) {
        var upstream = initialUpstream
        var downloaded = 0
        var uploaded = 0
        var pushed = false

        for attempt in 0...options.maxPushRetries {
            if attempt > 0 {
                progress(.downloading)
                try await fetch(session: session)
                upstream = try await inspector.resolveUpstream(branch: branch)
            }

            guard let upstream else {
                // The branch does not exist on GitHub yet: publish it.
                let hasCommits = try await git(["rev-parse", "--verify", "--quiet", "HEAD"], stage: .push, session: session).succeeded
                guard hasCommits else { pushed = true; break }
                progress(.uploading)
                let count = try await git(["rev-list", "--count", "HEAD"], stage: .push, session: session)
                switch try await push(remote: "origin", remoteBranch: branch, setUpstream: true, session: session) {
                case .pushed:
                    uploaded += Int(count.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                    pushed = true
                case .rejected:
                    continue
                }
                break
            }

            var (ahead, behind) = try await inspector.aheadBehind(upstream: upstream)
            if behind > 0 {
                progress(.merging)
                try await merge(upstream: upstream, localAhead: ahead, session: session)
                downloaded += behind
                (ahead, behind) = try await inspector.aheadBehind(upstream: upstream)
            }
            if ahead == 0 { pushed = true; break }

            progress(.uploading)
            let (remote, remoteBranch) = Self.split(upstream: upstream)
            switch try await push(remote: remote, remoteBranch: remoteBranch, setUpstream: false, session: session) {
            case .pushed:
                uploaded += ahead
                pushed = true
            case .rejected:
                continue
            }
            break
        }

        guard pushed else {
            throw SyncFailure(
                kind: .pushRejected, stage: .push,
                command: session.steps.last?.command ?? "git push",
                exitCode: session.steps.last?.exitCode,
                stderr: session.steps.last?.output ?? ""
            )
        }
        return (downloaded, uploaded)
    }

    private func performResolution(
        choices: [String: ConflictChoice],
        session: SyncSession,
        progress: @Sendable (SyncPhase) -> Void
    ) async throws -> SyncReport.Outcome {
        progress(.checking)
        let info = try await preflight()
        guard let branch = info.branch else { throw SyncFailure(kind: .detachedHead, stage: .preflight) }

        progress(.downloading)
        try await fetch(session: session)
        progress(.committing)
        let committed = try await commitLocalChanges(session: session)

        guard let upstream = try await inspector.resolveUpstream(branch: branch) else {
            throw SyncFailure(kind: .unknown, stage: .conflictResolution, message: String(localized: "远程分支不存在，无需解决冲突，请直接同步"))
        }

        // A ref that keeps the pre-resolution local commit reachable forever.
        let backupRef = "refs/gitcloud-sync/backup/\(Self.timestamp())"
        _ = try await gitChecked(["update-ref", backupRef, "HEAD"], stage: .conflictResolution, session: session)
        session.warnings.append(String(localized: "已创建备份引用 \(backupRef)，可随时恢复解决冲突前的本地版本。"))

        var (ahead, behind) = try await inspector.aheadBehind(upstream: upstream)
        var downloaded = 0
        if behind > 0 {
            progress(.merging)
            let mergeArgs = ["merge", "--no-ff", "--no-commit", upstream]
            let result = try await git(mergeArgs, stage: .conflictResolution, session: session)
            if !result.succeeded {
                let conflicts = try await conflictFiles()
                guard !conflicts.isEmpty else {
                    try await abortMergeIfNeeded(session: session)
                    throw SyncFailure.from(result, stage: .conflictResolution, command: "git " + mergeArgs.joined(separator: " "))
                }
                let unanswered = conflicts.filter { choices[$0.path] == nil }
                guard unanswered.isEmpty else {
                    // New conflicts appeared since the user made their choices.
                    try await abortMergeIfNeeded(session: session)
                    throw ConflictDetected(files: conflicts)
                }
                do {
                    for file in conflicts {
                        try await apply(choices[file.path] ?? .keepBoth, to: file, session: session)
                    }
                    let remaining = try await inspector.unmergedPaths()
                    guard remaining.isEmpty else {
                        throw SyncFailure(kind: .unknown, stage: .conflictResolution,
                                          message: String(localized: "仍有未解决的冲突：\(remaining.joined(separator: String(localized: "、")))"))
                    }
                } catch {
                    try? await abortMergeIfNeeded(session: session)
                    throw error
                }
            }
            if RepositoryInspector.inProgressOperation(gitDirectory: info.gitDirectory) == .merge {
                _ = try await gitChecked(["commit", "--no-edit", "--quiet"], stage: .commit, session: session,
                                         extraConfig: try await identityConfig())
            }
            downloaded = behind
            (ahead, behind) = try await inspector.aheadBehind(upstream: upstream)
        }

        var uploaded = 0
        if ahead > 0 {
            progress(.uploading)
            let (remote, remoteBranch) = Self.split(upstream: upstream)
            switch try await push(remote: remote, remoteBranch: remoteBranch, setUpstream: false, session: session) {
            case .pushed:
                uploaded = ahead
            case .rejected:
                throw SyncFailure(kind: .pushRejected, stage: .push,
                                  message: String(localized: "冲突已在本地解决，但远程又有新提交"),
                                  suggestion: String(localized: "冲突解决结果已保存在本地提交中，请再次点击同步。"))
            }
        }
        return .success(SyncSummary(committedFiles: committed, downloadedCommits: downloaded, uploadedCommits: uploaded))
    }

    private func performRestore(
        _ target: RestoreTarget,
        description: String,
        session: SyncSession,
        progress: @Sendable (SyncPhase) -> Void
    ) async throws -> SyncReport.Outcome {
        progress(.checking)
        let info = try await preflight()
        guard let branch = info.branch else { throw SyncFailure(kind: .detachedHead, stage: .preflight) }
        guard !info.isUnborn else {
            throw SyncFailure(kind: .unknown, stage: .restore, message: String(localized: "仓库还没有任何历史版本"))
        }
        let verify = try await git(["rev-parse", "--verify", "--quiet", "\(target.commit)^{commit}"], stage: .restore, session: session)
        guard verify.succeeded else {
            throw SyncFailure(kind: .unknown, stage: .restore, command: "git rev-parse --verify \(target.commit)",
                              message: String(localized: "找不到所选的历史版本"), suggestion: String(localized: "请关闭历史窗口后重新打开再试。"))
        }

        // Start from the newest version so the restore is not undone by the next merge. Without a
        // connection the restore still happens locally and is uploaded by a later sync.
        progress(.downloading)
        var offline: SyncFailure?
        do {
            try await fetch(session: session)
        } catch let failure as SyncFailure where failure.isConnectivity {
            offline = failure
        }

        progress(.committing)
        let committed = try await commitLocalChanges(session: session)
        var downloaded = 0
        if offline == nil, let upstream = try await inspector.resolveUpstream(branch: branch) {
            let (ahead, behind) = try await inspector.aheadBehind(upstream: upstream)
            if behind > 0 {
                progress(.merging)
                try await merge(upstream: upstream, localAhead: ahead, session: session)
                downloaded = behind
            }
        }

        progress(.restoring)
        let backupRef = "refs/gitcloud-sync/backup/\(Self.timestamp())"
        _ = try await gitChecked(["update-ref", backupRef, "HEAD"], stage: .restore, session: session)
        session.warnings.append(String(localized: "已创建备份引用 \(backupRef)，记录了恢复前的版本。"))
        try await applyRestore(target, session: session)

        let staged = try await gitChecked(["diff", "--cached", "--name-status", "-z"], stage: .restore, session: session)
        let files = Self.parseNameStatus(staged.stdoutData)
        if files.isEmpty {
            session.warnings.append(String(localized: "当前内容已经与所选版本相同，无需恢复。"))
        } else {
            _ = try await gitChecked(["commit", "--quiet", "-m", restoreMessage(description: description, files: files)],
                                     stage: .commit, session: session, extraConfig: try await identityConfig())
        }

        if var failure = offline {
            if files.isEmpty, committed == 0 { return .noChanges }
            failure.message = String(localized: "已在本地恢复，但无法连接 GitHub")
            failure.suggestion = String(localized: "恢复结果已保存在本地提交中，联网后下次同步会自动上传。")
            throw failure
        }

        var uploaded = 0
        do {
            let upstream = try await inspector.resolveUpstream(branch: branch)
            let result = try await integrateAndPush(branch: branch, upstream: upstream, session: session, progress: progress)
            downloaded += result.downloaded
            uploaded = result.uploaded
        } catch var failure as SyncFailure where failure.isConnectivity {
            failure.message = String(localized: "已在本地恢复，但上传失败：") + failure.message
            failure.suggestion = String(localized: "恢复结果已保存在本地提交中，联网后下次同步会自动上传。")
            throw failure
        }

        if files.isEmpty, committed == 0, downloaded == 0, uploaded == 0 { return .noChanges }
        return .success(SyncSummary(committedFiles: committed, downloadedCommits: downloaded,
                                    uploadedCommits: uploaded, restoredFiles: files.count))
    }

    private func applyRestore(_ target: RestoreTarget, session: SyncSession) async throws {
        switch target {
        case .file(let path, let sourcePath, let commit) where path == sourcePath:
            _ = try await gitChecked(["restore", "--source=\(commit)", "--staged", "--worktree", "--", ":(literal)\(path)"],
                                     stage: .restore, session: session)
        case .file(let path, let sourcePath, let commit):
            // The file had another name in that version: write the old content under today's name.
            let blob = try await client.run(["cat-file", "blob", "\(commit):\(sourcePath)"], timeout: options.localTimeout)
            guard blob.succeeded else {
                throw SyncFailure.from(blob, stage: .restore, command: "git cat-file blob \(commit):\(sourcePath)")
            }
            let url = repoURL.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try blob.stdoutData.write(to: url, options: .atomic)
            _ = try await gitChecked(["add", "--", ":(literal)\(path)"], stage: .restore, session: session)
        case .repository(let commit):
            // Matches every tracked file to that commit, removing files it did not have. Untracked
            // and ignored files are left alone.
            _ = try await gitChecked(["restore", "--source=\(commit)", "--staged", "--worktree", "--", ":/"],
                                     stage: .restore, session: session, timeout: options.localTimeout * 3)
            try await dropRestoredIgnoredFiles(session: session)
        }
    }

    /// Old versions may contain files that are ignored today (for example a `.DS_Store` that was
    /// committed before the ignore rules existed). Those are not brought back.
    private func dropRestoredIgnoredFiles(session: SyncSession) async throws {
        let staged = try await gitChecked(["diff", "--cached", "--name-only", "--diff-filter=A", "-z"], stage: .restore, session: session)
        let added = staged.stdoutData.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        guard !added.isEmpty else { return }
        let input = Data((added.joined(separator: "\0") + "\0").utf8)
        let check = try await client.run(["check-ignore", "--no-index", "-z", "--stdin"], timeout: options.localTimeout, stdin: input)
        let ignored = check.stdoutData.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        guard !ignored.isEmpty else { return }
        _ = try await gitChecked(["restore", "--source=HEAD", "--staged", "--worktree", "--"] + ignored.map { ":(literal)\($0)" },
                                 stage: .restore, session: session)
        session.warnings.append(String(localized: "以下文件属于忽略规则，未恢复：\(ignored.prefix(5).joined(separator: String(localized: "、")))\(ignored.count > 5 ? String(localized: " 等 \(ignored.count) 个") : "")"))
    }

    // MARK: - Steps

    private func preflight() async throws -> RepositoryInfo {
        let info = try await inspector.inspect()
        guard FileManager.default.isWritableFile(atPath: info.topLevelPath) else {
            throw SyncFailure(kind: .permissionDenied, stage: .preflight,
                              message: String(localized: "没有写入该文件夹的权限：\(info.topLevelPath)"))
        }
        if info.indexLocked {
            throw SyncFailure(kind: .indexLocked, stage: .preflight,
                              stderr: String(localized: "存在 \(info.gitDirectory)/index.lock"))
        }
        if let operation = info.inProgressOperation {
            var message = String(localized: "仓库中有未完成的\(operation.displayName)操作")
            if !info.unmergedFiles.isEmpty {
                message += String(localized: "，未解决的文件：\(info.unmergedFiles.prefix(10).joined(separator: String(localized: "、")))")
            }
            throw SyncFailure(kind: .operationInProgress, stage: .preflight, message: message)
        }
        if !info.unmergedFiles.isEmpty {
            throw SyncFailure(kind: .operationInProgress, stage: .preflight,
                              message: String(localized: "仓库中存在未解决的冲突文件：\(info.unmergedFiles.prefix(10).joined(separator: String(localized: "、")))"))
        }
        if info.isDetached {
            throw SyncFailure(kind: .detachedHead, stage: .preflight)
        }
        if info.remoteURL == nil {
            throw SyncFailure(kind: .noRemote, stage: .preflight)
        }
        do {
            try IgnoreRules.apply(patterns: options.ignorePatterns, gitDirectory: URL(fileURLWithPath: info.gitDirectory))
        } catch {
            throw SyncFailure(kind: .permissionDenied, stage: .ignoreRules, stderr: error.localizedDescription)
        }
        return info
    }

    private func fetch(session: SyncSession) async throws {
        _ = try await gitChecked(["fetch", "--prune", "origin"], stage: .fetch, session: session,
                                 timeout: options.networkTimeout)
    }

    /// Stages everything (minus oversized files) and commits. Returns the number of files committed.
    private func commitLocalChanges(session: SyncSession) async throws -> Int {
        let status = try await gitChecked(["status", "--porcelain=v1", "-z", "--untracked-files=all"],
                                          stage: .stage, session: session, timeout: options.localTimeout)
        let entries = StatusEntry.parse(status.stdoutData)
        guard !entries.isEmpty else { return 0 }

        var excluded: [String] = []
        for entry in entries where !entry.isDeletion {
            let url = repoURL.appendingPathComponent(entry.path)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  (attrs[.type] as? FileAttributeType) == .typeRegular,
                  let size = (attrs[.size] as? NSNumber)?.int64Value else { continue }
            if size > options.largeFileLimitBytes {
                excluded.append(entry.path)
                session.warnings.append(String(localized: "「\(entry.path)」大小 \(Self.formatBytes(size))，超过上传上限 \(Self.formatBytes(options.largeFileLimitBytes))，已跳过（文件保留在本地）。建议移出仓库或使用 Git LFS。"))
            } else if size > options.largeFileWarningBytes {
                session.warnings.append(String(localized: "「\(entry.path)」大小 \(Self.formatBytes(size))，接近 GitHub 100 MB 限制，上传可能较慢。"))
            }
        }

        var addArgs = ["add", "-A", "--", "."]
        addArgs += excluded.map { ":(exclude,literal)\($0)" }
        _ = try await gitChecked(addArgs, stage: .stage, session: session, timeout: options.localTimeout * 3)

        let staged = try await gitChecked(["diff", "--cached", "--name-status", "-z"], stage: .stage, session: session,
                                          timeout: options.localTimeout)
        let files = Self.parseNameStatus(staged.stdoutData)
        guard !files.isEmpty else { return 0 }

        let message = commitMessage(files: files)
        _ = try await gitChecked(["commit", "--quiet", "-m", message], stage: .commit, session: session,
                                 timeout: options.localTimeout, extraConfig: try await identityConfig())
        return files.count
    }

    private func merge(upstream: String, localAhead: Int, session: SyncSession) async throws {
        if localAhead == 0 {
            _ = try await gitChecked(["merge", "--ff-only", "--quiet", upstream], stage: .merge, session: session,
                                     timeout: options.localTimeout)
            return
        }
        let args = ["merge", "--no-edit", "-m", String(localized: "GitSync：合并来自 GitHub 的更新（\(options.machineName)）"), upstream]
        let result = try await git(args, stage: .merge, session: session, timeout: options.localTimeout,
                                   extraConfig: try await identityConfig())
        guard !result.succeeded else { return }

        let conflicts = try await conflictFiles()
        let gitDir = try await gitDirectory()
        if !conflicts.isEmpty || RepositoryInspector.inProgressOperation(gitDirectory: gitDir) == .merge {
            try await abortMergeIfNeeded(session: session)
            throw ConflictDetected(files: conflicts)
        }
        throw SyncFailure.from(result, stage: .merge, command: "git merge --no-edit \(upstream)")
    }

    private enum PushOutcome { case pushed, rejected }

    private func push(remote: String, remoteBranch: String, setUpstream: Bool, session: SyncSession) async throws -> PushOutcome {
        var args = ["push", "--porcelain"]
        if setUpstream { args.append("--set-upstream") }
        args += [remote, "HEAD:refs/heads/\(remoteBranch)"]
        let result = try await git(args, stage: .push, session: session, timeout: options.networkTimeout)
        if result.succeeded { return .pushed }
        // The remote moved between our fetch and push. Depending on timing git reports a
        // classic rejection or a lost race on the server-side ref lock; both are retried
        // (bounded by maxPushRetries) after fetching and merging again.
        let output = (result.stdout + "\n" + result.stderr).lowercased()
        let raceMarkers = ["[rejected]", "non-fast-forward", "fetch first", "cannot lock ref", "stale info"]
        if !result.timedOut, raceMarkers.contains(where: output.contains) {
            return .rejected
        }
        throw SyncFailure.from(result, stage: .push, command: "git " + args.joined(separator: " "))
    }

    private func apply(_ choice: ConflictChoice, to file: ConflictFile, session: SyncSession) async throws {
        let path = file.path
        switch choice {
        case .keepLocal:
            if file.localExists {
                _ = try await gitChecked(["checkout", "--ours", "--", path], stage: .conflictResolution, session: session)
                _ = try await gitChecked(["add", "--", path], stage: .conflictResolution, session: session)
            } else {
                _ = try await gitChecked(["rm", "--quiet", "--", path], stage: .conflictResolution, session: session)
            }
        case .keepRemote:
            if file.remoteExists {
                _ = try await gitChecked(["checkout", "--theirs", "--", path], stage: .conflictResolution, session: session)
                _ = try await gitChecked(["add", "--", path], stage: .conflictResolution, session: session)
            } else {
                _ = try await gitChecked(["rm", "--quiet", "--", path], stage: .conflictResolution, session: session)
            }
        case .keepBoth:
            switch (file.localExists, file.remoteExists) {
            case (true, true):
                _ = try await gitChecked(["checkout", "--ours", "--", path], stage: .conflictResolution, session: session)
                let remote = try await gitChecked(["show", ":3:\(path)"], stage: .conflictResolution, session: session)
                let copyPath = uniqueCopyPath(for: path)
                let copyURL = repoURL.appendingPathComponent(copyPath)
                try FileManager.default.createDirectory(at: copyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try remote.stdoutData.write(to: copyURL, options: .withoutOverwriting)
                _ = try await gitChecked(["add", "--", path, copyPath], stage: .conflictResolution, session: session)
                session.warnings.append(String(localized: "「\(path)」保留本地版本，远程版本另存为「\(copyPath)」。"))
            case (true, false):
                _ = try await gitChecked(["checkout", "--ours", "--", path], stage: .conflictResolution, session: session)
                _ = try await gitChecked(["add", "--", path], stage: .conflictResolution, session: session)
            case (false, true):
                _ = try await gitChecked(["checkout", "--theirs", "--", path], stage: .conflictResolution, session: session)
                _ = try await gitChecked(["add", "--", path], stage: .conflictResolution, session: session)
            case (false, false):
                _ = try await gitChecked(["rm", "--quiet", "--", path], stage: .conflictResolution, session: session)
            }
        }
    }

    private func abortMergeIfNeeded(session: SyncSession) async throws {
        let gitDir = try await gitDirectory()
        guard RepositoryInspector.inProgressOperation(gitDirectory: gitDir) == .merge else { return }
        let result = try await git(["merge", "--abort"], stage: .merge, session: session)
        if !result.succeeded || RepositoryInspector.inProgressOperation(gitDirectory: gitDir) == .merge {
            throw SyncFailure(
                kind: .operationInProgress, stage: .merge, command: "git merge --abort",
                exitCode: result.exitCode, stderr: result.stderr,
                message: String(localized: "检测到冲突后自动中止合并失败，仓库仍处于合并状态"),
                suggestion: String(localized: "为避免数据丢失，GitSync 没有执行任何其他清理。请在 GitHub Desktop 中查看并处理该仓库。")
            )
        }
    }

    // MARK: - Helpers

    private func conflictFiles() async throws -> [ConflictFile] {
        let result = try await client.run(["ls-files", "-u", "-z"], timeout: options.localTimeout)
        guard result.succeeded else { return [] }
        var stages: [String: Set<Int>] = [:]
        var order: [String] = []
        for record in result.stdoutData.split(separator: 0) {
            // "<mode> <sha> <stage>\t<path>"
            let line = String(decoding: record, as: UTF8.self)
            guard let tab = line.firstIndex(of: "\t") else { continue }
            let meta = line[..<tab].split(separator: " ")
            let path = String(line[line.index(after: tab)...])
            guard meta.count == 3, let stage = Int(meta[2]) else { continue }
            if stages[path] == nil { order.append(path) }
            stages[path, default: []].insert(stage)
        }
        return order.map { path in
            let set = stages[path] ?? []
            return ConflictFile(path: path, localExists: set.contains(2), remoteExists: set.contains(3))
        }
    }

    private func identityConfig() async throws -> [String] {
        let email = try await client.run(["config", "--get", "user.email"], timeout: 15)
        let name = try await client.run(["config", "--get", "user.name"], timeout: 15)
        var config: [String] = []
        if !name.succeeded || name.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            config += ["-c", "user.name=\(options.fallbackIdentity.name)"]
        }
        if !email.succeeded || email.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            config += ["-c", "user.email=\(options.fallbackIdentity.email)"]
        }
        return config
    }

    private func gitDirectory() async throws -> String {
        let result = try await client.run(["rev-parse", "--absolute-git-dir"], timeout: 15)
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commitMessage(files: [(status: String, path: String)]) -> String {
        let date = Date().formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute())
        var lines = [String(localized: "GitSync：\(options.machineName) 自动同步 \(date)"), ""]
        lines.append(String(localized: "共 \(files.count) 个文件变更："))
        for file in files.prefix(30) {
            lines.append("\(file.status)\t\(file.path)")
        }
        if files.count > 30 { lines.append(String(localized: "……以及另外 \(files.count - 30) 个文件")) }
        return lines.joined(separator: "\n")
    }

    private func restoreMessage(description: String, files: [(status: String, path: String)]) -> String {
        var lines = [String(localized: "GitSync：\(options.machineName) 恢复\(description)"), ""]
        lines.append(String(localized: "共 \(files.count) 个文件："))
        for file in files.prefix(30) {
            lines.append("\(file.status)\t\(file.path)")
        }
        if files.count > 30 { lines.append(String(localized: "……以及另外 \(files.count - 30) 个文件")) }
        return lines.joined(separator: "\n")
    }

    private func uniqueCopyPath(for path: String) -> String {
        let directory = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        var candidate = Self.copyName(for: name, label: String(localized: "远程版本 \(Self.timestamp(short: true))"))
        var counter = 2
        while FileManager.default.fileExists(atPath: repoURL.appendingPathComponent(directory).appendingPathComponent(candidate).path) {
            candidate = Self.copyName(for: name, label: String(localized: "远程版本 \(Self.timestamp(short: true)) \(counter)"))
            counter += 1
        }
        return directory.isEmpty ? candidate : "\(directory)/\(candidate)"
    }

    static func copyName(for fileName: String, label: String) -> String {
        let ext = (fileName as NSString).pathExtension
        let base = (fileName as NSString).deletingPathExtension
        if ext.isEmpty || base.isEmpty { return "\(fileName) (\(label))" }
        return "\(base) (\(label)).\(ext)"
    }

    static func split(upstream: String) -> (remote: String, branch: String) {
        guard let slash = upstream.firstIndex(of: "/") else { return ("origin", upstream) }
        return (String(upstream[..<slash]), String(upstream[upstream.index(after: slash)...]))
    }

    static func parseNameStatus(_ data: Data) -> [(status: String, path: String)] {
        let fields = data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        var files: [(String, String)] = []
        var i = 0
        while i < fields.count {
            let status = fields[i]
            i += 1
            // Renames / copies carry two paths.
            let pathCount = (status.hasPrefix("R") || status.hasPrefix("C")) ? 2 : 1
            guard i + pathCount <= fields.count else { break }
            files.append((String(status.prefix(1)), fields[i + pathCount - 1]))
            i += pathCount
        }
        return files
    }

    static func timestamp(short: Bool = false) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = short ? "yyyy-MM-dd HHmm" : "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    @discardableResult
    private func git(
        _ args: [String],
        stage: SyncStage,
        session: SyncSession,
        timeout: TimeInterval? = nil,
        extraConfig: [String] = []
    ) async throws -> ProcessResult {
        let command = "git " + args.map(ProcessResult.shellQuote).joined(separator: " ")
        let result: ProcessResult
        do {
            result = try await client.run(args, timeout: timeout ?? options.localTimeout, extraConfig: extraConfig)
        } catch {
            throw SyncFailure(kind: .gitUnavailable, stage: stage, command: command, stderr: error.localizedDescription)
        }
        session.record(result, stage: stage, command: command)
        return result
    }

    private func gitChecked(
        _ args: [String],
        stage: SyncStage,
        session: SyncSession,
        timeout: TimeInterval? = nil,
        extraConfig: [String] = []
    ) async throws -> ProcessResult {
        let result = try await git(args, stage: stage, session: session, timeout: timeout, extraConfig: extraConfig)
        guard result.succeeded else {
            throw SyncFailure.from(result, stage: stage, command: "git " + args.map(ProcessResult.shellQuote).joined(separator: " "))
        }
        return result
    }
}
