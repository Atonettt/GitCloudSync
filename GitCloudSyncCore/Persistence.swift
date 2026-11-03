import Foundation

/// A repository the user added. Removing it never touches the folder or GitHub.
public struct RepositoryConfig: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var path: String
    public var displayName: String
    public var autoSyncEnabled: Bool
    public var addedAt: Date
    public var lastSyncAt: Date?
    public var lastAttemptAt: Date?
    public var lastStatus: SyncStatus
    public var lastMessage: String?
    public var lastFailure: SyncFailure?
    public var conflictFiles: [ConflictFile]
    /// Set when a conflict was detected; automatic sync skips the repository until resolved.
    public var pausedForConflict: Bool

    public init(
        id: UUID = UUID(),
        path: String,
        displayName: String,
        autoSyncEnabled: Bool = true,
        addedAt: Date = Date()
    ) {
        self.id = id
        self.path = path
        self.displayName = displayName
        self.autoSyncEnabled = autoSyncEnabled
        self.addedAt = addedAt
        self.lastSyncAt = nil
        self.lastAttemptAt = nil
        self.lastStatus = .notSynced
        self.lastMessage = nil
        self.lastFailure = nil
        self.conflictFiles = []
        self.pausedForConflict = false
    }

    enum CodingKeys: String, CodingKey {
        case id, path, displayName, autoSyncEnabled, addedAt, lastSyncAt, lastAttemptAt
        case lastStatus, lastMessage, lastFailure, conflictFiles, pausedForConflict
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        path = try c.decode(String.self, forKey: .path)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
            ?? URL(fileURLWithPath: path).lastPathComponent
        autoSyncEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoSyncEnabled) ?? true
        addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
        lastSyncAt = try c.decodeIfPresent(Date.self, forKey: .lastSyncAt)
        lastAttemptAt = try c.decodeIfPresent(Date.self, forKey: .lastAttemptAt)
        let status = try c.decodeIfPresent(SyncStatus.self, forKey: .lastStatus) ?? .notSynced
        // A transient status persisted mid-sync (e.g. the app was killed) is not a real result.
        lastStatus = status.isActive ? .notSynced : status
        lastMessage = try c.decodeIfPresent(String.self, forKey: .lastMessage)
        lastFailure = try c.decodeIfPresent(SyncFailure.self, forKey: .lastFailure)
        conflictFiles = try c.decodeIfPresent([ConflictFile].self, forKey: .conflictFiles) ?? []
        pausedForConflict = try c.decodeIfPresent(Bool.self, forKey: .pausedForConflict) ?? false
    }
}

public struct AppSettings: Codable, Sendable, Equatable {
    public static let presetIntervals = [1, 3, 5, 10, 15, 30, 60]

    public var autoSyncEnabled = false
    public var intervalMinutes = 5
    public var maxConcurrentSyncs = 2
    public var ignorePatterns = IgnoreRules.defaultPatterns
    public var largeFileLimitMB = 100
    public var customGitPath: String?
    public var oauthClientID = ""
    public var showDockIcon = true
    public var syncOnWake = true
    public var notifyOnFailure = true
    public var notifyOnConflict = true
    public var notifyOnAuthProblem = true
    public var notifyOnChanges = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let d = AppSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        autoSyncEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoSyncEnabled) ?? d.autoSyncEnabled
        intervalMinutes = max(1, try c.decodeIfPresent(Int.self, forKey: .intervalMinutes) ?? d.intervalMinutes)
        maxConcurrentSyncs = try c.decodeIfPresent(Int.self, forKey: .maxConcurrentSyncs) ?? d.maxConcurrentSyncs
        ignorePatterns = try c.decodeIfPresent([String].self, forKey: .ignorePatterns) ?? d.ignorePatterns
        largeFileLimitMB = try c.decodeIfPresent(Int.self, forKey: .largeFileLimitMB) ?? d.largeFileLimitMB
        customGitPath = try c.decodeIfPresent(String.self, forKey: .customGitPath)
        oauthClientID = try c.decodeIfPresent(String.self, forKey: .oauthClientID) ?? d.oauthClientID
        showDockIcon = try c.decodeIfPresent(Bool.self, forKey: .showDockIcon) ?? d.showDockIcon
        syncOnWake = try c.decodeIfPresent(Bool.self, forKey: .syncOnWake) ?? d.syncOnWake
        notifyOnFailure = try c.decodeIfPresent(Bool.self, forKey: .notifyOnFailure) ?? d.notifyOnFailure
        notifyOnConflict = try c.decodeIfPresent(Bool.self, forKey: .notifyOnConflict) ?? d.notifyOnConflict
        notifyOnAuthProblem = try c.decodeIfPresent(Bool.self, forKey: .notifyOnAuthProblem) ?? d.notifyOnAuthProblem
        notifyOnChanges = try c.decodeIfPresent(Bool.self, forKey: .notifyOnChanges) ?? d.notifyOnChanges
    }

    enum CodingKeys: String, CodingKey {
        case autoSyncEnabled, intervalMinutes, maxConcurrentSyncs, ignorePatterns, largeFileLimitMB
        case customGitPath, oauthClientID, showDockIcon, syncOnWake
        case notifyOnFailure, notifyOnConflict, notifyOnAuthProblem, notifyOnChanges
    }
}

public struct PersistedState: Codable, Sendable, Equatable {
    public var version = 1
    public var settings = AppSettings()
    public var repositories: [RepositoryConfig] = []

    public init(settings: AppSettings = AppSettings(), repositories: [RepositoryConfig] = []) {
        self.settings = settings
        self.repositories = repositories
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        settings = try c.decodeIfPresent(AppSettings.self, forKey: .settings) ?? AppSettings()
        repositories = try c.decodeIfPresent([RepositoryConfig].self, forKey: .repositories) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case version, settings, repositories
    }
}

public enum LogLevel: String, Codable, Sendable, CaseIterable {
    case info, success, warning, error

    public var displayName: String {
        switch self {
        case .info: "信息"
        case .success: "成功"
        case .warning: "警告"
        case .error: "错误"
        }
    }
}

public struct SyncLogEntry: Codable, Sendable, Identifiable, Hashable {
    public var id = UUID()
    public var date = Date()
    public var repositoryID: UUID?
    public var repositoryName: String
    public var stage: String
    public var level: LogLevel
    public var result: String
    public var exitCode: Int32?
    public var detail: String?
    public var duration: TimeInterval?

    public init(
        repositoryID: UUID? = nil,
        repositoryName: String,
        stage: String,
        level: LogLevel,
        result: String,
        exitCode: Int32? = nil,
        detail: String? = nil,
        duration: TimeInterval? = nil
    ) {
        self.repositoryID = repositoryID
        self.repositoryName = repositoryName
        self.stage = stage
        self.level = level
        self.result = result
        self.exitCode = exitCode
        self.detail = detail
        self.duration = duration
    }

    public var copyText: String {
        var text = "[\(date.formatted(date: .numeric, time: .standard))] \(repositoryName) · \(stage) · \(level.displayName)\n\(result)"
        if let exitCode { text += "\n退出码：\(exitCode)" }
        if let duration { text += String(format: "\n耗时：%.2f 秒", duration) }
        if let detail, !detail.isEmpty { text += "\n\n\(detail)" }
        return text
    }
}

/// Atomic JSON file storage.
public struct JSONFileStore<Value: Codable>: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static func applicationSupportURL(fileName: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("GitCloudSync", isDirectory: true).appendingPathComponent(fileName)
    }

    public func load() throws -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Value.self, from: data)
    }

    public func save(_ value: Value) throws {
        // Default (reference-date seconds) keeps full Date precision.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
