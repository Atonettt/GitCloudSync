import Foundation

/// One committed version of the repository, as shown in the history UI.
public struct HistoryCommit: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case autoSync
        case merge
        case restore
        case other
    }

    public var id: String
    public var parents: [String]
    public var date: Date
    public var author: String
    public var subject: String
    public var changes: [HistoryChange]

    public init(id: String, parents: [String], date: Date, author: String, subject: String, changes: [HistoryChange] = []) {
        self.id = id
        self.parents = parents
        self.date = date
        self.author = author
        self.subject = subject
        self.changes = changes
    }

    public var shortID: String { String(id.prefix(7)) }

    // GitSync writes its commit messages in the app's language, so both forms are recognised:
    //   GitSync：<Mac> 自动同步 <date>        GitSync: <Mac> auto-sync <date>
    //   GitSync：合并来自 GitHub 的更新（<Mac>）  GitSync: merged updates from GitHub (<Mac>)
    //   GitSync：<Mac> 恢复…                  GitSync: <Mac> restored …
    static let prefixes = ["GitSync：", "GitSync: "]
    static let autoSyncMarkers = [" 自动同步 ", " auto-sync "]  // i18n-ignore
    static let mergeMarkers = ["合并来自 GitHub 的更新", "merged updates from GitHub"]  // i18n-ignore
    static let restoreMarkers = [" 恢复", " restored "]  // i18n-ignore

    /// The message after the "GitSync：" / "GitSync: " prefix; nil for commits not made by GitSync.
    private var body: Substring? {
        Self.prefixes.first(where: subject.hasPrefix).map { subject.dropFirst($0.count) }
    }

    public var kind: Kind {
        guard let body else { return .other }
        if Self.mergeMarkers.contains(where: body.hasPrefix) { return .merge }
        if Self.autoSyncMarkers.contains(where: body.contains) { return .autoSync }
        if Self.restoreMarkers.contains(where: body.contains) { return .restore }
        return .other
    }

    /// The Mac that made the commit, parsed from GitSync's own commit messages; nil otherwise.
    public var machine: String? {
        guard let body else { return nil }
        switch kind {
        case .merge:
            guard let open = body.lastIndex(where: { $0 == "（" || $0 == "(" }),
                  let close = body.lastIndex(where: { $0 == "）" || $0 == ")" }), open < close else { return nil }
            return String(body[body.index(after: open)..<close])
        case .autoSync:
            return Self.firstRange(of: Self.autoSyncMarkers, in: body).map { String(body[..<$0.lowerBound]) }
        case .restore:
            return Self.firstRange(of: Self.restoreMarkers, in: body).map { String(body[..<$0.lowerBound]) }
        case .other:
            return nil
        }
    }

    /// "MacBook Pro" for GitSync commits, the author name for everything else.
    public var source: String { machine ?? author }

    /// A one-line description for the timeline.
    public var title: String {
        switch kind {
        case .autoSync: String(localized: "自动同步")
        case .merge: String(localized: "合并来自 GitHub 的更新")
        case .restore:
            // What was restored, without the "GitSync：<Mac> " lead-in.
            String((body ?? "").dropFirst(machine.map { $0.count + 1 } ?? 0))
        case .other: subject
        }
    }

    private static func firstRange(of markers: [String], in text: Substring) -> Range<Substring.Index>? {
        markers.lazy.compactMap { text.range(of: $0) }.first
    }
}

public struct HistoryChange: Sendable, Hashable {
    /// A, M, D, R, C or T.
    public var status: String
    public var path: String
    /// The previous name for renames and copies.
    public var oldPath: String?

    public init(status: String, path: String, oldPath: String? = nil) {
        self.status = status
        self.path = path
        self.oldPath = oldPath
    }

    public var displayStatus: String {
        switch status {
        case "A": String(localized: "新增")
        case "D": String(localized: "删除")
        case "R": String(localized: "重命名")
        case "C": String(localized: "复制")
        default: String(localized: "修改")
        }
    }
}

/// One version of a single file.
public struct FileVersion: Sendable, Hashable, Identifiable {
    public var commit: HistoryCommit
    /// The file's name in that commit (differs from today's name after a rename).
    public var path: String
    /// true when this commit deleted the file; such a version has no content.
    public var isDeletion: Bool
    public var size: Int64?

    public var id: String { commit.id + "\u{0}" + path }
}

/// A file that existed in the history but is gone from the current version.
public struct DeletedFile: Sendable, Hashable, Identifiable {
    public var path: String
    /// The commit that deleted it.
    public var deletedIn: HistoryCommit
    /// The last commit that still contained the file.
    public var lastVersionCommit: String
    public var size: Int64?

    public var id: String { path }
}

/// The effect of moving the whole repository back to a commit.
public struct RestorePreview: Sendable, Hashable {
    public var modified: [String] = []
    /// Files that were deleted after the target time and come back.
    public var restored: [String] = []
    /// Files created after the target time; they are removed (and stay in history).
    public var removed: [String] = []

    public var isEmpty: Bool { modified.isEmpty && restored.isEmpty && removed.isEmpty }
    public var total: Int { modified.count + restored.count + removed.count }
}

/// Read-only queries over a repository's history. Nothing here changes the repository.
public struct HistoryBrowser: Sendable {
    public let client: GitClient
    public var timeout: TimeInterval = 60

    public init(client: GitClient) {
        self.client = client
    }

    /// Commits on the current branch's first-parent line, newest first. Each entry is the
    /// state of this folder right after one sync, which is what "go back to this time" restores.
    public func timeline(limit: Int = 200, skip: Int = 0) async throws -> [HistoryCommit] {
        let result = try await git([
            "log", "--first-parent", "--diff-merges=first-parent", "-z", "--name-status",
            "--format=\(Self.format)", "-n", String(limit), "--skip", String(skip), "HEAD", "--",
        ])
        return Self.parseLog(result.stdoutData)
    }

    /// Paths of every file in `commit` (the latest one by default), sorted for display.
    public func trackedFiles(at commit: String = "HEAD") async throws -> [String] {
        let result = try await git(["ls-tree", "-r", "--name-only", "-z", commit])
        return result.stdoutData.split(separator: 0)
            .map { String(decoding: $0, as: UTF8.self) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Every committed version of `path`, newest first, following renames.
    public func versions(of path: String, limit: Int = 300) async throws -> [FileVersion] {
        let result = try await git([
            "log", "--follow", "-z", "--name-status", "--format=\(Self.format)",
            "-n", String(limit), "HEAD", "--", path,
        ])
        var versions: [FileVersion] = []
        for commit in Self.parseLog(result.stdoutData) {
            // With --follow the only change listed is the file itself, under its name at the time.
            guard let change = commit.changes.first else { continue }
            versions.append(FileVersion(commit: commit, path: change.path, isDeletion: change.status == "D"))
        }
        let sizes = try await blobSizes(versions.filter { !$0.isDeletion }.map { ($0.commit.id, $0.path) })
        for index in versions.indices where !versions[index].isDeletion {
            versions[index].size = sizes["\(versions[index].commit.id):\(versions[index].path)"]
        }
        return versions
    }

    /// Files deleted at some point and not present in the latest commit, most recent deletion first.
    public func deletedFiles(scanLimit: Int = 2000) async throws -> [DeletedFile] {
        let result = try await git([
            "log", "--diff-filter=D", "-z", "--name-status", "--no-renames", "--format=\(Self.format)",
            "-n", String(scanLimit), "HEAD", "--",
        ])
        let current = Set(try await trackedFiles())
        var seen = Set<String>()
        var files: [DeletedFile] = []
        for commit in Self.parseLog(result.stdoutData) {
            guard let parent = commit.parents.first else { continue }
            for change in commit.changes where change.status == "D" {
                guard !current.contains(change.path), seen.insert(change.path).inserted else { continue }
                // Recreated on disk but not synced yet: restoring would overwrite the new file.
                let onDisk = client.repositoryURL.appendingPathComponent(change.path).path
                guard !FileManager.default.fileExists(atPath: onDisk) else { continue }
                files.append(DeletedFile(path: change.path, deletedIn: commit, lastVersionCommit: parent))
            }
        }
        let sizes = try await blobSizes(files.map { ($0.lastVersionCommit, $0.path) })
        for index in files.indices {
            files[index].size = sizes["\(files[index].lastVersionCommit):\(files[index].path)"]
        }
        return files
    }

    /// What restoring the whole repository to `commit` would change, compared with the latest commit.
    /// Uncommitted local edits are not listed; a restore saves them into history first.
    public func previewRestore(to commit: String) async throws -> RestorePreview {
        let result = try await git(["diff", "--name-status", "--no-renames", "-z", "HEAD", commit, "--"])
        var preview = RestorePreview()
        for change in SyncEngine.parseNameStatus(result.stdoutData) {
            switch change.status {
            case "A": preview.restored.append(change.path)
            case "D": preview.removed.append(change.path)
            default: preview.modified.append(change.path)
            }
        }
        return preview
    }

    /// The raw bytes of `path` as committed in `commit`.
    public func content(of path: String, at commit: String) async throws -> Data {
        let result = try await git(["cat-file", "blob", "\(commit):\(path)"], timeout: 300)
        return result.stdoutData
    }

    /// Writes a version to a temporary folder (for Quick Look or comparing). The repository is untouched.
    /// `date` only labels the file name.
    public func exportForPreview(path: String, commit: String, date: Date) async throws -> URL {
        let data = try await content(of: path, at: commit)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitSync-Compare", isDirectory: true)
            .appendingPathComponent(String(commit.prefix(12)), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = SyncEngine.copyName(for: (path as NSString).lastPathComponent,
                                       label: Self.versionLabel(date))
        let target = folder.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: target)
        try data.write(to: target)
        return target
    }

    /// Saves a version next to today's file as "name (2026-11-01 1530 版本).ext" without touching
    /// the original. Returns the repository-relative path of the copy; the next sync uploads it.
    public func saveCopy(path: String, commit: String, date: Date, besides currentPath: String? = nil) async throws -> String {
        let data = try await content(of: path, at: commit)
        let anchor = currentPath ?? path
        let directory = (anchor as NSString).deletingLastPathComponent
        let name = (anchor as NSString).lastPathComponent
        let label = Self.versionLabel(date)
        var candidate = SyncEngine.copyName(for: name, label: label)
        var counter = 2
        let folderURL = client.repositoryURL.appendingPathComponent(directory)
        while FileManager.default.fileExists(atPath: folderURL.appendingPathComponent(candidate).path) {
            candidate = SyncEngine.copyName(for: name, label: "\(label) \(counter)")
            counter += 1
        }
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try data.write(to: folderURL.appendingPathComponent(candidate), options: .withoutOverwriting)
        return directory.isEmpty ? candidate : "\(directory)/\(candidate)"
    }

    static func versionLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        return formatter.string(from: date) + String(localized: " 版本")
    }

    // MARK: - Parsing

    /// Record separator, then hash, parents, commit time, author, subject.
    static let format = "%x1e%H%x1f%P%x1f%ct%x1f%an%x1f%s"

    /// Parses `git log -z --name-status --format=<format>` output.
    static func parseLog(_ data: Data) -> [HistoryCommit] {
        var commits: [HistoryCommit] = []
        for record in data.split(separator: 0x1e, omittingEmptySubsequences: true) {
            let headerEnd = record.firstIndex(of: 0) ?? record.endIndex
            let fields = String(decoding: record[record.startIndex..<headerEnd], as: UTF8.self)
                .split(separator: "\u{1f}", omittingEmptySubsequences: false)
                .map(String.init)
            guard fields.count >= 5, let seconds = TimeInterval(fields[2]) else { continue }
            var commit = HistoryCommit(
                id: fields[0],
                parents: fields[1].split(separator: " ").map(String.init),
                date: Date(timeIntervalSince1970: seconds),
                author: fields[3],
                subject: fields[4...].joined(separator: "\u{1f}")
            )
            if headerEnd < record.endIndex {
                commit.changes = parseChanges(record[record.index(after: headerEnd)...])
            }
            commits.append(commit)
        }
        return commits
    }

    private static func parseChanges(_ data: Data.SubSequence) -> [HistoryChange] {
        let tokens = data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        var changes: [HistoryChange] = []
        var i = 0
        while i < tokens.count {
            // Each commit's list starts on a new line; status letters never contain one.
            let status = tokens[i].trimmingCharacters(in: .newlines)
            i += 1
            guard let letter = status.first, letter.isLetter else { continue }
            let pathCount = (letter == "R" || letter == "C") ? 2 : 1
            guard i + pathCount <= tokens.count else { break }
            if pathCount == 2 {
                changes.append(HistoryChange(status: String(letter), path: tokens[i + 1], oldPath: tokens[i]))
            } else {
                changes.append(HistoryChange(status: String(letter), path: tokens[i]))
            }
            i += pathCount
        }
        return changes
    }

    // MARK: - Helpers

    /// Sizes of `commit:path` blobs in one `cat-file --batch-check` call, keyed by "commit:path".
    private func blobSizes(_ objects: [(commit: String, path: String)]) async throws -> [String: Int64] {
        guard !objects.isEmpty else { return [:] }
        // Paths containing a newline cannot be expressed in batch input; they simply get no size.
        let keys = objects.map { "\($0.commit):\($0.path)" }.filter { !$0.contains("\n") }
        let input = Data((keys.joined(separator: "\n") + "\n").utf8)
        let result = try await client.run(["cat-file", "--batch-check=%(objectsize)"], timeout: timeout, stdin: input)
        guard result.succeeded else { return [:] }
        let lines = result.stdout.split(separator: "\n", omittingEmptySubsequences: false)
        var sizes: [String: Int64] = [:]
        for (key, line) in zip(keys, lines) {
            if let size = Int64(line) { sizes[key] = size }
        }
        return sizes
    }

    private func git(_ args: [String], timeout: TimeInterval? = nil) async throws -> ProcessResult {
        let result = try await client.run(args, timeout: timeout ?? self.timeout)
        guard result.succeeded else {
            throw SyncFailure.from(result, stage: .history, command: "git " + args.map(ProcessResult.shellQuote).joined(separator: " "))
        }
        return result
    }
}
