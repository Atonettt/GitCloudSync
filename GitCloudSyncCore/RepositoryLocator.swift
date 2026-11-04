import Foundation

/// Finds a repository folder again after it was moved, renamed or put in the Trash.
public enum RepositoryLocation: Equatable, Sendable {
    /// The folder is where it was.
    case unchanged
    /// The folder moved (on the same disk) and was found here.
    case moved(URL)
    /// The folder is in the Trash.
    case inTrash(URL)
    /// The folder can't be found.
    case missing
}

/// What makes a folder "the same repository": its origin URL and a commit it contains.
public struct RepositoryIdentity: Sendable, Equatable {
    public var remote: String?
    public var commit: String?

    public init(remote: String?, commit: String?) {
        self.remote = remote
        self.commit = commit
    }
}

public struct RepositoryLocator: Sendable {
    public let git: GitEnvironment

    public init(git: GitEnvironment) {
        self.git = git
    }

    /// A bookmark that keeps pointing at the folder when it moves or is renamed on the same volume
    /// (the mechanism behind Finder aliases).
    public static func bookmark(for folder: URL) -> Data? {
        try? folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Where the folder is now. `path` is the last known path; `bookmark` is used when it's gone.
    public static func locate(path: String, bookmark: Data?) -> RepositoryLocation {
        if isDirectory(path), !isInTrash(URL(fileURLWithPath: path)) { return .unchanged }
        guard let bookmark else { return .missing }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                 relativeTo: nil, bookmarkDataIsStale: &stale),
              isDirectory(url.path) else { return .missing }
        if isInTrash(url) { return .inTrash(url) }
        return url.standardizedFileURL.path == URL(fileURLWithPath: path).standardizedFileURL.path ? .unchanged : .moved(url)
    }

    public static func isInTrash(_ url: URL) -> Bool {
        let components = url.standardizedFileURL.pathComponents
        return components.contains(".Trash") || components.contains(".Trashes")
    }

    /// The origin URL and current commit of the repository at `folder`.
    public func identity(of folder: URL) async -> RepositoryIdentity {
        let client = GitClient(repositoryURL: folder, git: git)
        let remote = try? await client.run(["remote", "get-url", "origin"], timeout: 15)
        let head = try? await client.run(["rev-parse", "--verify", "--quiet", "HEAD"], timeout: 15)
        return RepositoryIdentity(
            remote: remote?.succeeded == true ? remote?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
            commit: head?.succeeded == true ? head?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        )
    }

    /// Whether `candidate` is the repository described by `expected`: the root of a Git repository
    /// with the same origin, or one that contains the commit last seen. With nothing known, any
    /// repository root is accepted.
    public func matches(_ candidate: URL, expected: RepositoryIdentity) async -> Bool {
        let client = GitClient(repositoryURL: candidate, git: git)
        guard let top = try? await client.run(["rev-parse", "--show-toplevel"], timeout: 15), top.succeeded,
              RepositoryCreator.canonicalPath(top.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
                == RepositoryCreator.canonicalPath(candidate.path) else { return false }
        let actual = await identity(of: candidate)
        if let remote = expected.remote, let other = actual.remote,
           Self.normalized(remote) == Self.normalized(other) { return true }
        if let commit = expected.commit,
           let check = try? await client.run(["cat-file", "-e", "\(commit)^{commit}"], timeout: 15), check.succeeded {
            return true
        }
        return expected.remote == nil && expected.commit == nil
    }

    /// Folders with the same name that Spotlight knows about and that match `expected`, for when
    /// the bookmark can't find a moved folder.
    public func candidates(named name: String, expected: RepositoryIdentity, limit: Int = 5) async -> [URL] {
        let query = "kMDItemFSName == '\(name.replacingOccurrences(of: "'", with: "\\'"))' && kMDItemContentType == 'public.folder'"
        guard let result = try? await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/mdfind"),
                                                        arguments: [query], timeout: 20),
              result.succeeded else { return [] }
        var found: [URL] = []
        for line in result.stdout.split(separator: "\n") {
            let url = URL(fileURLWithPath: String(line))
            guard !Self.isInTrash(url), FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) else { continue }
            if await matches(url, expected: expected) { found.append(url) }
            if found.count == limit { break }
        }
        return found
    }

    static func normalized(_ remote: String) -> String {
        RepositoryInfo.webURL(fromRemote: remote)?.absoluteString.lowercased() ?? remote.lowercased()
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}
