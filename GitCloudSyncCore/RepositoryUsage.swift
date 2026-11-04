import Foundation

/// Disk space used by a repository: the files themselves and the history kept in `.git`.
public struct RepositoryUsage: Sendable, Equatable {
    public enum Level: Sendable, Equatable {
        case normal
        /// Above GitHub's recommended size.
        case large
        /// Above the size at which GitHub starts warning.
        case veryLarge
    }

    /// GitHub recommends keeping repositories below 1 GB.
    public static let largeThreshold: Int64 = 1 << 30
    /// GitHub sends warnings above 5 GB.
    public static let veryLargeThreshold: Int64 = 5 << 30

    /// Everything in the folder except `.git`.
    public var fileBytes: Int64
    /// Git's object store: every version ever synced.
    public var historyBytes: Int64
    public var measuredAt: Date

    public init(fileBytes: Int64, historyBytes: Int64, measuredAt: Date = Date()) {
        self.fileBytes = fileBytes
        self.historyBytes = historyBytes
        self.measuredAt = measuredAt
    }

    public var level: Level {
        if historyBytes >= Self.veryLargeThreshold { return .veryLarge }
        if historyBytes >= Self.largeThreshold { return .large }
        return .normal
    }
}

/// How much of the history one path accounts for, across all of its versions.
public struct HistoryFileUsage: Sendable, Hashable, Identifiable {
    public var path: String
    public var versions: Int
    /// Compressed size of all versions as stored in `.git`.
    public var storedBytes: Int64
    /// The largest single version, uncompressed.
    public var largestVersionBytes: Int64

    public var id: String { path }
}

/// Read-only size measurements. Nothing in the repository changes.
public struct RepositoryUsageScanner: Sendable {
    public let client: GitClient
    public var timeout: TimeInterval = 180

    public init(client: GitClient) {
        self.client = client
    }

    /// Measures both sizes. Pass `reusingFileBytes` when the files are known not to have changed:
    /// walking a large folder is the expensive part, while the history size comes from Git cheaply.
    public func measure(reusingFileBytes knownFileBytes: Int64? = nil) async throws -> RepositoryUsage {
        let history = try await historySize()
        if let knownFileBytes {
            return RepositoryUsage(fileBytes: knownFileBytes, historyBytes: history)
        }
        let gitDir = URL(fileURLWithPath: try await git(["rev-parse", "--absolute-git-dir"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines))
        let files = Self.allocatedSize(of: client.repositoryURL, skipping: gitDir)
        return RepositoryUsage(fileBytes: files, historyBytes: history)
    }

    /// Size of Git's object store from `git count-objects -v`, which reads a few directory
    /// listings instead of every file under `.git`.
    public func historySize() async throws -> Int64 {
        let output = try await git(["count-objects", "-v"]).stdout
        return Self.parseCountObjects(output)
    }

    /// Adds loose, packed and garbage sizes (reported in KiB) from `git count-objects -v`.
    static func parseCountObjects(_ output: String) -> Int64 {
        var kib: Int64 = 0
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, ["size", "size-pack", "size-garbage"].contains(parts[0]),
                  let value = Int64(parts[1]) else { continue }
            kib += value
        }
        return kib * 1024
    }

    /// Paths whose versions take the most space in history, largest first. Includes files that
    /// have since been deleted, because their old versions are still stored.
    public func largestFiles(limit: Int = 15) async throws -> [HistoryFileUsage] {
        let objects = try await git(["rev-list", "--objects", "--all"])
        guard !objects.stdoutData.isEmpty else { return [] }
        let sizes = try await git(
            ["cat-file", "--batch-check=%(objecttype) %(objectsize) %(objectsize:disk) %(rest)"],
            stdin: objects.stdoutData
        )
        var usage: [String: HistoryFileUsage] = [:]
        for line in sizes.stdout.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false)
            guard fields.count == 4, fields[0] == "blob", !fields[3].isEmpty,
                  let size = Int64(fields[1]), let disk = Int64(fields[2]) else { continue }
            let path = String(fields[3])
            var entry = usage[path] ?? HistoryFileUsage(path: path, versions: 0, storedBytes: 0, largestVersionBytes: 0)
            entry.versions += 1
            entry.storedBytes += disk
            entry.largestVersionBytes = max(entry.largestVersionBytes, size)
            usage[path] = entry
        }
        return Array(usage.values.sorted { $0.storedBytes > $1.storedBytes }.prefix(limit))
    }

    /// Bytes allocated on disk for everything under `url` (what Finder and `du` report).
    static func allocatedSize(of url: URL, skipping excluded: URL?) -> Int64 {
        let keys: [URLResourceKey] = [.isDirectoryKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        let excludedPath = excluded?.standardizedFileURL.path
        var total: Int64 = 0
        for case let item as URL in enumerator {
            let values = try? item.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if let excludedPath, item.standardizedFileURL.path == excludedPath { enumerator.skipDescendants() }
                continue
            }
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return total
    }

    private func git(_ args: [String], stdin: Data? = nil) async throws -> ProcessResult {
        let result = try await client.run(args, timeout: timeout, stdin: stdin)
        guard result.succeeded else {
            throw SyncFailure.from(result, stage: .inspect, command: "git " + args.map(ProcessResult.shellQuote).joined(separator: " "))
        }
        return result
    }
}
