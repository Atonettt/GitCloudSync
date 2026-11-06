import Darwin
import Foundation

/// GitHub's rules for repository names.
public enum RepositoryNaming {
    public static let maxLength = 100

    /// A valid name derived from a folder name: Chinese is written in pinyin, accents are dropped,
    /// and other unsupported characters become "-" ("研究资料 2026" → "yan-jiu-zi-liao-2026").
    /// Returns "" when nothing usable is left.
    public static func suggestedName(for folderName: String) -> String {
        // Only names with Chinese characters go through pinyin; the transform also respaces punctuation.
        let hasChinese = folderName.unicodeScalars.contains { $0.properties.isIdeographic }
        let pinyin = hasChinese ? folderName.applyingTransform(.mandarinToLatin, reverse: false) ?? folderName : folderName
        let latin = pinyin.applyingTransform(.stripDiacritics, reverse: false) ?? pinyin
        var result = ""
        for scalar in latin.unicodeScalars {
            if isAllowed(scalar) {
                result.unicodeScalars.append(scalar)
            } else if !result.hasSuffix("-") {
                result.append("-")
            }
        }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        if result.lowercased().hasSuffix(".git") { result.removeLast(4) }
        return String(result.prefix(maxLength))
    }

    /// nil when `name` can be used as is; otherwise a message for the user.
    public static func problem(with name: String) -> String? {
        if name.isEmpty { return String(localized: "请输入仓库名") }
        if name.count > maxLength { return String(localized: "仓库名不能超过 \(maxLength) 个字符") }
        if name == "." || name == ".." { return String(localized: "仓库名不能是「.」或「..」") }
        if name.lowercased().hasSuffix(".git") { return String(localized: "仓库名不能以 .git 结尾") }
        if !name.unicodeScalars.allSatisfy(isAllowed) {
            return String(localized: "GitHub 仓库名只能包含英文字母、数字、-、_ 和 .（本地文件夹名不受影响，可以保留中文）")
        }
        return nil
    }

    private static func isAllowed(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a"..."z", "A"..."Z", "0"..."9", "-", "_", ".": true
        default: false
        }
    }
}

/// What a folder holds before it is turned into a synced repository.
public struct FolderPreview: Sendable {
    public enum Kind: Sendable, Equatable {
        /// A plain folder; `git init` will be run.
        case plainFolder
        /// Already a Git repository without an origin remote.
        case repositoryWithoutRemote(commits: Int)
        /// Already linked to a remote; it can be added directly.
        case linkedRepository(remote: String)
        /// The folder sits inside another repository rooted at `root`.
        case insideRepository(root: String)
    }

    public var kind: Kind
    public var fileCount: Int
    public var totalBytes: Int64
    /// Files larger than the upload limit, which sync skips. Relative paths with sizes.
    public var oversized: [(path: String, bytes: Int64)]
    /// True when the walk stopped early because the folder is huge.
    public var truncated: Bool
    /// The folder is synced by iCloud Drive (for example Desktop & Documents).
    public var isInICloud: Bool
}

/// Turns a plain folder into a repository that GitSync can sync. Network work (creating the
/// GitHub repository) lives in the app; this type only touches the local folder.
public struct RepositoryCreator: Sendable {
    public let git: GitEnvironment

    public init(git: GitEnvironment) {
        self.git = git
    }

    /// Folders that must never become a repository.
    public static func refusalReason(for folder: URL) -> String? {
        let path = canonicalPath(folder.path)
        let home = canonicalPath(FileManager.default.homeDirectoryForCurrentUser.path)
        let forbidden = ["/", home, home + "/Desktop", home + "/Documents", home + "/Downloads", home + "/Library",
                         "/Applications", "/System", "/Library", "/Users", "/Volumes"]
        if forbidden.contains(path) {
            return String(localized: "不能把「\(folder.lastPathComponent)」整个文件夹作为仓库，请在里面新建一个文件夹再拖进来。")
        }
        if path.hasPrefix(home + "/Library/") && !path.hasPrefix(home + "/Library/Mobile Documents/") {
            return String(localized: "不能使用系统资源库中的文件夹。")
        }
        return nil
    }

    public func preview(folder: URL, largeFileLimit: Int64, ignorePatterns: [String], maxEntries: Int = 100_000) async throws -> FolderPreview {
        let client = GitClient(repositoryURL: folder, git: git)
        let kind: FolderPreview.Kind
        let top = try await client.run(["rev-parse", "--show-toplevel"], timeout: 15)
        if top.succeeded {
            let root = top.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let remote = try await client.run(["remote", "get-url", "origin"], timeout: 15)
            if Self.canonicalPath(root) != Self.canonicalPath(folder.path) {
                kind = .insideRepository(root: root)
            } else if remote.succeeded {
                kind = .linkedRepository(remote: remote.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
            } else {
                let count = try await client.run(["rev-list", "--count", "HEAD"], timeout: 15)
                kind = .repositoryWithoutRemote(commits: Int(count.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
            }
        } else {
            kind = .plainFolder
        }

        let scan = Self.scan(folder: folder, largeFileLimit: largeFileLimit, ignorePatterns: ignorePatterns, maxEntries: maxEntries)
        let iCloud = (try? folder.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem ?? false
        return FolderPreview(kind: kind, fileCount: scan.count, totalBytes: scan.bytes, oversized: scan.oversized,
                             truncated: scan.truncated, isInICloud: iCloud)
    }

    /// Prepares the folder for its first sync: `git init` when needed, GitSync's ignore rules,
    /// a private commit identity, and `origin` pointing at `remoteURL`.
    /// Returns true when this call created the repository.
    @discardableResult
    public func prepare(folder: URL, remoteURL: String, identity: GitIdentity?, ignorePatterns: [String]) async throws -> Bool {
        let client = GitClient(repositoryURL: folder, git: git)
        var created = false
        let top = try await client.run(["rev-parse", "--show-toplevel"], timeout: 15)
        if !top.succeeded {
            try await checked(client, ["init", "--quiet", "-b", "main"])
            created = true
        } else {
            let root = top.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.canonicalPath(root) == Self.canonicalPath(folder.path) else {
                throw SyncFailure(kind: .unknown, stage: .preflight, message: String(localized: "该文件夹位于另一个 Git 仓库内：\(root)"))
            }
        }
        let gitDir = try await checked(client, ["rev-parse", "--absolute-git-dir"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try IgnoreRules.apply(patterns: ignorePatterns, gitDirectory: URL(fileURLWithPath: gitDir))

        // Commits go to GitHub, so use the account's private noreply address rather than
        // whatever personal email the global git config holds.
        if let identity {
            let localEmail = try await client.run(["config", "--local", "--get", "user.email"], timeout: 15)
            if !localEmail.succeeded || localEmail.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try await checked(client, ["config", "--local", "user.name", identity.name])
                try await checked(client, ["config", "--local", "user.email", identity.email])
            }
        }

        let existing = try await client.run(["remote", "get-url", "origin"], timeout: 15)
        if existing.succeeded {
            let current = existing.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard current == remoteURL else {
                throw SyncFailure(kind: .unknown, stage: .preflight, message: String(localized: "该仓库已经关联了远程地址 \(current)"))
            }
        } else {
            try await checked(client, ["remote", "add", "origin", remoteURL])
        }
        return created
    }

    /// Downloads the GitHub repository at `remoteURL` into `destination`, for a folder that was
    /// deleted locally. `destination` must not exist yet or be an empty folder, so nothing local is
    /// ever replaced. The clone goes to a hidden folder next to it first and is moved into place
    /// only when complete. GitSync's ignore rules and commit identity are then applied as for a
    /// new repository.
    public func download(remoteURL: String, to destination: URL, credential: GitCredential?,
                         identity: GitIdentity?, ignorePatterns: [String], timeout: TimeInterval = 3600) async throws {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: destination.path, isDirectory: &isDirectory) {
            let contents = isDirectory.boolValue
                ? ((try? fm.contentsOfDirectory(atPath: destination.path)) ?? []).filter { $0 != ".DS_Store" }
                : [destination.lastPathComponent]
            guard contents.isEmpty else {
                throw SyncFailure(kind: .unknown, stage: .fetch,
                                  message: String(localized: "「\(destination.path)」已存在且不是空的，GitSync 不会覆盖它。"))
            }
        }
        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".\(destination.lastPathComponent).gitsync-download-\(UUID().uuidString.prefix(8))")
        defer { try? fm.removeItem(at: staging) }

        let client = GitClient(repositoryURL: parent, git: git, credential: credential)
        let args = ["clone", "--quiet", remoteURL, staging.path]
        let result = try await client.run(args, timeout: timeout)
        guard result.succeeded else {
            throw SyncFailure.from(result, stage: .fetch, command: "git clone \(remoteURL)")
        }
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: staging, to: destination)
        try await prepare(folder: destination, remoteURL: remoteURL, identity: identity, ignorePatterns: ignorePatterns)
    }

    /// True when the remote has no branches yet, so linking to it cannot clash with local history.
    public func remoteIsEmpty(_ remoteURL: String, credential: GitCredential?, in folder: URL) async throws -> Bool {
        let client = GitClient(repositoryURL: folder, git: git, credential: credential)
        let result = try await client.run(["ls-remote", "--heads", remoteURL], timeout: 60)
        guard result.succeeded else {
            throw SyncFailure.from(result, stage: .fetch, command: "git ls-remote --heads \(remoteURL)")
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Helpers

    /// The real path with symlinks resolved (/var → /private/var), for comparing with git's output.
    static func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    @discardableResult
    private func checked(_ client: GitClient, _ args: [String]) async throws -> ProcessResult {
        let result = try await client.run(args, timeout: 60)
        guard result.succeeded else {
            throw SyncFailure.from(result, stage: .preflight, command: "git " + args.map(ProcessResult.shellQuote).joined(separator: " "))
        }
        return result
    }

    static func scan(folder: URL, largeFileLimit: Int64, ignorePatterns: [String], maxEntries: Int)
        -> (count: Int, bytes: Int64, oversized: [(path: String, bytes: Int64)], truncated: Bool) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else {
            return (0, 0, [], false)
        }
        let base = folder.standardizedFileURL.path
        var count = 0
        var bytes: Int64 = 0
        var oversized: [(String, Int64)] = []
        var visited = 0
        for case let url as URL in enumerator {
            visited += 1
            if visited > maxEntries { return (count, bytes, oversized, true) }
            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: Set(keys))
            if name == ".git" || isIgnored(name, patterns: ignorePatterns) {
                if values?.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            guard values?.isRegularFile == true else { continue }
            let size = Int64(values?.fileSize ?? 0)
            count += 1
            bytes += size
            if size > largeFileLimit {
                var relative = url.standardizedFileURL.path
                if relative.hasPrefix(base + "/") { relative.removeFirst(base.count + 1) }
                oversized.append((relative, size))
            }
        }
        return (count, bytes, oversized, false)
    }

    /// Matches a file name against the simple glob patterns used by the ignore rules.
    static func isIgnored(_ name: String, patterns: [String]) -> Bool {
        patterns.contains { pattern in
            let glob = pattern.hasSuffix("/") ? String(pattern.dropLast()) : pattern
            guard !glob.contains("/") else { return false }
            return fnmatch(glob, name, 0) == 0
        }
    }
}
