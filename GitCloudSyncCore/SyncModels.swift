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
        case .notSynced: "未同步"
        case .pending: "等待同步"
        case .checking: "正在检查"
        case .downloading: "下载中"
        case .uploading: "上传中"
        case .success: "同步成功"
        case .noChanges: "无文件变化"
        case .failed: "同步失败"
        case .needsAuth: "需要认证"
        case .conflict: "存在冲突"
        case .networkUnavailable: "网络不可用"
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
    case checking, downloading, committing, merging, uploading

    public var status: SyncStatus {
        switch self {
        case .checking: .checking
        case .downloading, .merging: .downloading
        case .committing, .uploading: .uploading
        }
    }

    public var displayName: String {
        switch self {
        case .checking: "正在检查"
        case .downloading: "正在获取远程更新"
        case .committing: "正在提交本地修改"
        case .merging: "正在整合远程更新"
        case .uploading: "正在上传"
        }
    }
}

public enum SyncStage: String, Codable, Sendable {
    case preflight, ignoreRules, fetch, stage, commit, merge, push, conflictResolution, inspect, auth

    public var displayName: String {
        switch self {
        case .preflight: "同步前检查"
        case .ignoreRules: "应用忽略规则"
        case .fetch: "获取远程更新"
        case .stage: "检测本地修改"
        case .commit: "提交本地修改"
        case .merge: "整合远程更新"
        case .push: "上传到 GitHub"
        case .conflictResolution: "解决冲突"
        case .inspect: "读取仓库信息"
        case .auth: "GitHub 认证"
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
        if result.timedOut { stderr = "（操作超时，已在 \(Int(result.duration)) 秒后终止）\n" + stderr }
        return SyncFailure(
            kind: kind,
            stage: stage,
            command: command,
            exitCode: result.exitCode,
            stderr: String(stderr.prefix(8000))
        )
    }

    public var mappedStatus: SyncStatus {
        switch kind {
        case .authentication, .repositoryNotFound: .needsAuth
        case .network: .networkUnavailable
        case .operationInProgress: .conflict
        default: .failed
        }
    }

    /// Text suitable for the clipboard / bug reports.
    public var fullReport: String {
        """
        阶段：\(stage.displayName)
        说明：\(message)
        命令：\(command.isEmpty ? "-" : command)
        退出码：\(exitCode.map(String.init) ?? "-")
        时间：\(date.formatted(date: .numeric, time: .standard))
        Git 输出：
        \(stderr.isEmpty ? "（无）" : stderr)

        处理建议：\(suggestion)
        """
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
        case (true, true): "本地与远程都修改了此文件"
        case (true, false): "远程删除了此文件，本地修改了它"
        case (false, true): "本地删除了此文件，远程修改了它"
        case (false, false): "双方都删除或重命名了此文件"
        }
    }
}

public enum ConflictChoice: String, Codable, Sendable, CaseIterable {
    case keepLocal, keepRemote, keepBoth

    public var displayName: String {
        switch self {
        case .keepLocal: "保留本地"
        case .keepRemote: "使用远程"
        case .keepBoth: "保留两者"
        }
    }
}

public enum InProgressOperation: String, Codable, Sendable {
    case merge, rebase, cherryPick, revert

    public var displayName: String {
        switch self {
        case .merge: "合并 (merge)"
        case .rebase: "变基 (rebase)"
        case .cherryPick: "拣选 (cherry-pick)"
        case .revert: "还原 (revert)"
        }
    }
}

public struct SyncSummary: Codable, Sendable, Hashable {
    public var committedFiles: Int
    public var downloadedCommits: Int
    public var uploadedCommits: Int

    public var text: String {
        var parts: [String] = []
        if committedFiles > 0 { parts.append("提交 \(committedFiles) 个文件") }
        if downloadedCommits > 0 { parts.append("下载 \(downloadedCommits) 个提交") }
        if uploadedCommits > 0 { parts.append("上传 \(uploadedCommits) 个提交") }
        return parts.isEmpty ? "已是最新" : parts.joined(separator: "，")
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
        let code = timedOut ? "超时" : "退出码 \(exitCode)"
        return "[\(stage.displayName)] \(command) → \(code)，\(String(format: "%.2f", duration)) 秒"
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

    public var status: SyncStatus {
        switch outcome {
        case .success: .success
        case .noChanges: .noChanges
        case .conflict: .conflict
        case .failure(let failure): failure.mappedStatus
        }
    }
}
