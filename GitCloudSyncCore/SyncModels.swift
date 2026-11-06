import Foundation

/// User-visible status of a repository.
public enum SyncStatus: String, Codable, Sendable, CaseIterable {
    case notSynced
    case pending
    case checking
    case downloading
    case uploading
    case success
    case noChanges
    case failed
    case needsAuth
    case conflict
    case networkUnavailable

    public var displayName: String {
        switch self {
        case .notSynced: String(localized: "未同步")
        case .pending: String(localized: "等待同步")
        case .checking: String(localized: "正在检查")
        case .downloading: String(localized: "下载中")
        case .uploading: String(localized: "上传中")
        case .success: String(localized: "同步成功")
        case .noChanges: String(localized: "无文件变化")
        case .failed: String(localized: "同步失败")
        case .needsAuth: String(localized: "需要认证")
        case .conflict: String(localized: "存在冲突")
        case .networkUnavailable: String(localized: "网络不可用")
        }
    }

    public var isActive: Bool {
        switch self {
        case .pending, .checking, .downloading, .uploading: true
        default: false
        }
    }

    public var isProblem: Bool {
        switch self {
        case .failed, .needsAuth, .conflict, .networkUnavailable: true
        default: false
        }
    }
}

/// Fine-grained progress reported by the engine while it runs.
public enum SyncPhase: String, Sendable {
    case checking, downloading, committing, merging, restoring, uploading

    public var status: SyncStatus {
        switch self {
        case .checking, .restoring: .checking
        case .downloading, .merging: .downloading
        case .committing, .uploading: .uploading
        }
    }

    public var displayName: String {
        switch self {
        case .checking: String(localized: "正在检查")
        case .downloading: String(localized: "正在获取远程更新")
        case .committing: String(localized: "正在提交本地修改")
        case .merging: String(localized: "正在整合远程更新")
        case .restoring: String(localized: "正在恢复历史版本")
        case .uploading: String(localized: "正在上传")
        }
    }
}

public enum SyncStage: String, Codable, Sendable {
    case preflight, ignoreRules, fetch, stage, commit, merge, push, conflictResolution, restore, history, inspect, auth

    public var displayName: String {
        switch self {
        case .preflight: String(localized: "同步前检查")
        case .ignoreRules: String(localized: "应用忽略规则")
        case .fetch: String(localized: "获取远程更新")
        case .stage: String(localized: "检测本地修改")
        case .commit: String(localized: "提交本地修改")
        case .merge: String(localized: "整合远程更新")
        case .push: String(localized: "上传到 GitHub")
        case .conflictResolution: String(localized: "解决冲突")
        case .restore: String(localized: "恢复历史版本")
        case .history: String(localized: "读取历史版本")
        case .inspect: String(localized: "读取仓库信息")
        case .auth: String(localized: "GitHub 认证")
        }
    }
}

public enum FailureKind: String, Codable, Sendable {
    case authentication
    case repositoryNotFound
    case network
    case serverUnavailable
    case timeout
    case folderMissing
    case permissionDenied
    case notARepository
    case noRemote
    case detachedHead
    case unbornWithRemote
    case operationInProgress
    case indexLocked
    case largeFile
    case missingIdentity
    case pushRejected
    case mergeBlocked
    case unrelatedHistories
    case gitUnavailable
    case unknown
}

/// A failed sync step with everything needed to explain it.
public struct SyncFailure: Error, Codable, Sendable, Hashable {
    public var kind: FailureKind
    public var stage: SyncStage
    public var command: String
    public var exitCode: Int32?
    public var stderr: String
    public var message: String
    public var suggestion: String
    public var date: Date

    public init(
        kind: FailureKind,
        stage: SyncStage,
        command: String = "",
        exitCode: Int32? = nil,
        stderr: String = "",
        message: String? = nil,
        suggestion: String? = nil,
        date: Date = Date()
    ) {
        self.kind = kind
        self.stage = stage
        self.command = command
        self.exitCode = exitCode
        self.stderr = stderr
        self.message = message ?? GitErrorClassifier.message(for: kind, stage: stage)
        self.suggestion = suggestion ?? GitErrorClassifier.suggestion(for: kind)
        self.date = date
    }

    public static func from(_ result: ProcessResult, stage: SyncStage, command: String) -> SyncFailure {
        let combined = result.stderr + "\n" + result.stdout
        let kind = GitErrorClassifier.classify(output: combined, timedOut: result.timedOut)
        var stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if stderr.isEmpty { stderr = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
        if result.timedOut { stderr = String(localized: "（操作超时，已在 \(Int(result.duration)) 秒后终止）\n") + stderr }
        return SyncFailure(
            kind: kind,
            stage: stage,
            command: command,
            exitCode: result.exitCode,
            stderr: String(stderr.prefix(8000))
        )
    }

    /// GitHub could not be reached; local work is unaffected and a later sync can finish the job.
    public var isConnectivity: Bool {
        kind == .network || kind == .timeout || kind == .serverUnavailable
    }

    public var mappedStatus: SyncStatus {
        switch kind {
        case .authentication: .needsAuth
        // GitHub answers "not found" both for deleted repositories and for missing access, so
        // this is shown as a failure with an explanation rather than as a sign-in problem.
        case .network: .networkUnavailable
        case .operationInProgress: .conflict
        default: .failed
        }
    }

    /// Text suitable for the clipboard / bug reports.
    public var fullReport: String {
        String(localized: """
        阶段：\(stage.displayName)
        说明：\(message)
        命令：\(command.isEmpty ? "-" : command)
        退出码：\(exitCode.map(String.init) ?? "-")
        时间：\(date.formatted(date: .numeric, time: .standard))
        Git 输出：
        \(stderr.isEmpty ? String(localized: "（无）") : stderr)

        处理建议：\(suggestion)
        """)
    }
}

/// A file Git could not merge automatically.
public struct ConflictFile: Codable, Sendable, Hashable, Identifiable {
    public var path: String
    public var localExists: Bool
    public var remoteExists: Bool

    public var id: String { path }

    public init(path: String, localExists: Bool, remoteExists: Bool) {
        self.path = path
        self.localExists = localExists
        self.remoteExists = remoteExists
    }

    public var description: String {
        switch (localExists, remoteExists) {
        case (true, true): String(localized: "本地与远程都修改了此文件")
        case (true, false): String(localized: "远程删除了此文件，本地修改了它")
        case (false, true): String(localized: "本地删除了此文件，远程修改了它")
        case (false, false): String(localized: "双方都删除或重命名了此文件")
        }
    }
}

public enum ConflictChoice: String, Codable, Sendable, CaseIterable {
    case keepLocal, keepRemote, keepBoth

    public var displayName: String {
        switch self {
        case .keepLocal: String(localized: "保留本地")
        case .keepRemote: String(localized: "使用远程")
        case .keepBoth: String(localized: "保留两者")
        }
    }
}

public enum InProgressOperation: String, Codable, Sendable {
    case merge, rebase, cherryPick, revert

    public var displayName: String {
        switch self {
        case .merge: String(localized: "合并 (merge)")
        case .rebase: String(localized: "变基 (rebase)")
        case .cherryPick: String(localized: "拣选 (cherry-pick)")
        case .revert: String(localized: "还原 (revert)")
        }
    }
}

public struct SyncSummary: Codable, Sendable, Hashable {
    public var committedFiles: Int
    public var downloadedCommits: Int
    public var uploadedCommits: Int
    /// Files brought back from history by a restore.
    public var restoredFiles: Int = 0

    public var text: String {
        var parts: [String] = []
        if restoredFiles > 0 { parts.append(String(localized: "恢复 \(restoredFiles) 个文件")) }
        if committedFiles > 0 { parts.append(String(localized: "提交 \(committedFiles) 个文件")) }
        if downloadedCommits > 0 { parts.append(String(localized: "下载 \(downloadedCommits) 个提交")) }
        if uploadedCommits > 0 { parts.append(String(localized: "上传 \(uploadedCommits) 个提交")) }
        return parts.isEmpty ? String(localized: "已是最新") : parts.joined(separator: String(localized: "，"))
    }
}

public struct SyncStepRecord: Codable, Sendable, Hashable {
    public var stage: SyncStage
    public var command: String
    public var exitCode: Int32
    public var duration: TimeInterval
    public var timedOut: Bool
    public var output: String

    public var line: String {
        let code = timedOut ? String(localized: "超时") : String(localized: "退出码 \(exitCode)")
        return String(localized: "[\(stage.displayName)] \(command) → \(code)，\(String(format: "%.2f", duration)) 秒")
    }
}

public struct SyncReport: Sendable {
    public enum Outcome: Sendable {
        case success(SyncSummary)
        case noChanges
        case conflict([ConflictFile])
        case failure(SyncFailure)
    }

    public var outcome: Outcome
    public var steps: [SyncStepRecord]
    public var warnings: [String]
    public var info: RepositoryInfo?
    public var startedAt: Date
    public var duration: TimeInterval
    /// Files GitHub's version changed on disk during this run, relative to the repository.
    public var downloadedFiles: [String] = []

    public var status: SyncStatus {
        switch outcome {
        case .success: .success
        case .noChanges: .noChanges
        case .conflict: .conflict
        case .failure(let failure): failure.mappedStatus
        }
    }
}
