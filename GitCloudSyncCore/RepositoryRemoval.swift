import Foundation

/// What would be lost by deleting one side of a synced repository.
public struct DeletionCheck: Sendable, Equatable {
    /// Files changed locally and not committed yet.
    public var uncommittedFiles = 0
    /// Local commits that GitHub does not have.
    public var unpushedCommits = 0
    /// Commits on GitHub that this Mac has not downloaded (from a fresh fetch); nil when not checked.
    public var remoteOnlyCommits: Int?

    public init(uncommittedFiles: Int = 0, unpushedCommits: Int = 0, remoteOnlyCommits: Int? = nil) {
        self.uncommittedFiles = uncommittedFiles
        self.unpushedCommits = unpushedCommits
        self.remoteOnlyCommits = remoteOnlyCommits
    }

    /// Something exists only on this Mac.
    public var hasLocalOnlyWork: Bool { uncommittedFiles > 0 || unpushedCommits > 0 }
}

/// Local Git work around deleting a repository's GitHub copy or its local folder. Calling the
/// GitHub API and moving the folder to the Trash happen in the app.
public struct RepositoryRemoval: Sendable {
    public let client: GitClient
    public var timeout: TimeInterval = 120

    public init(client: GitClient) {
        self.client = client
    }

    /// Counts local work that GitHub does not have. With `fetch`, also downloads what is on
    /// GitHub (without merging) to count commits that exist only there.
    public func check(fetch: Bool) async throws -> DeletionCheck {
        var result = DeletionCheck()
        let status = try await git(["status", "--porcelain=v1", "-z", "--untracked-files=all"])
        result.uncommittedFiles = StatusEntry.parse(status.stdoutData).count

        if fetch {
            _ = try await git(["fetch", "--prune", "origin"], timeout: 300)
        }
        let hasHead = try await client.run(["rev-parse", "--verify", "--quiet", "HEAD"], timeout: 15).succeeded
        if hasHead {
            result.unpushedCommits = try await count(["rev-list", "--count", "HEAD", "--not", "--remotes=origin"])
            if fetch {
                result.remoteOnlyCommits = try await count(["rev-list", "--count", "--remotes=origin", "--not", "HEAD"])
            }
        } else if fetch {
            result.remoteOnlyCommits = try await count(["rev-list", "--count", "--remotes=origin"])
        }
        return result
    }

    /// After the GitHub repository was deleted: renames `origin` (keeping every downloaded
    /// commit reachable under the new name) and clears the branch's upstream, so the folder is
    /// local-only and can later be published to a new repository.
    /// Returns the new remote name.
    @discardableResult
    public func detachDeletedRemote(date: Date = Date()) async throws -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "github-deleted-\(formatter.string(from: date))"
        _ = try await git(["remote", "rename", "origin", name])
        // Fails harmlessly when the branch had no upstream (or the repository has no commits).
        _ = try await client.run(["branch", "--unset-upstream"], timeout: 15)
        return name
    }

    /// owner/name for a github.com remote, nil for anything else.
    public static func gitHubFullName(fromRemote remote: String) -> (owner: String, name: String)? {
        guard let url = RepositoryInfo.webURL(fromRemote: remote),
              url.host?.lowercased() == "github.com" else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (parts[0], parts[1])
    }

    private func count(_ args: [String]) async throws -> Int {
        Int(try await git(args).stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    private func git(_ args: [String], timeout: TimeInterval? = nil) async throws -> ProcessResult {
        let result = try await client.run(args, timeout: timeout ?? self.timeout)
        guard result.succeeded else {
            let stage: SyncStage = args.first == "fetch" ? .fetch : .inspect
            throw SyncFailure.from(result, stage: stage, command: "git " + args.map(ProcessResult.shellQuote).joined(separator: " "))
        }
        return result
    }
}
