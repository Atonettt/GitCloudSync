import Foundation

/// Snapshot of a repository, gathered with local read-only commands (no network).
public struct RepositoryInfo: Sendable, Hashable {
    public var topLevelPath: String
    public var gitDirectory: String
    public var branch: String?
    public var isUnborn: Bool
    public var remoteURL: String?
    public var upstream: String?
    public var ahead: Int
    public var behind: Int
    public var changedFiles: Int
    public var inProgressOperation: InProgressOperation?
    public var unmergedFiles: [String]
    public var indexLocked: Bool

    public var isDetached: Bool { branch == nil }

    /// https://github.com/owner/repo for both HTTPS and SSH remotes.
    public var webURL: URL? {
        guard let remoteURL else { return nil }
        return RepositoryInfo.webURL(fromRemote: remoteURL)
    }

    public static func webURL(fromRemote remote: String) -> URL? {
        var value = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("git@") {
            // git@github.com:owner/repo.git
            value = value.replacingOccurrences(of: "git@", with: "https://")
            if let range = value.range(of: ":", range: value.index(value.startIndex, offsetBy: 8)..<value.endIndex) {
                value.replaceSubrange(range, with: "/")
            }
        } else if value.hasPrefix("ssh://git@") {
            value = value.replacingOccurrences(of: "ssh://git@", with: "https://")
        }
        if value.hasSuffix(".git") { value.removeLast(4) }
        guard var components = URLComponents(string: value), components.scheme?.hasPrefix("http") == true else {
            return nil
        }
        components.user = nil
        components.password = nil
        return components.url
    }

    public var isGitHubRemote: Bool {
        remoteURL?.lowercased().contains("github.com") ?? false
    }
}

/// One entry of `git status --porcelain=v1 -z`.
public struct StatusEntry: Sendable, Hashable {
    public let index: Character
    public let worktree: Character
    public let path: String
    public let originalPath: String?

    public var isUntracked: Bool { index == "?" }
    public var isDeletion: Bool { index == "D" || worktree == "D" }
    public var isUnmerged: Bool {
        index == "U" || worktree == "U" || (index == "A" && worktree == "A") || (index == "D" && worktree == "D")
    }

    public static func parse(_ data: Data) -> [StatusEntry] {
        let fields = data.split(separator: 0, omittingEmptySubsequences: true)
        var entries: [StatusEntry] = []
        var i = 0
        while i < fields.count {
            let field = String(decoding: fields[i], as: UTF8.self)
            i += 1
            guard field.count >= 4 else { continue }
            let chars = Array(field)
            let x = chars[0], y = chars[1]
            let path = String(chars[3...])
            var original: String?
            if x == "R" || x == "C" || y == "R" || y == "C", i < fields.count {
                original = String(decoding: fields[i], as: UTF8.self)
                i += 1
            }
            entries.append(StatusEntry(index: x, worktree: y, path: path, originalPath: original))
        }
        return entries
    }
}

public struct RepositoryInspector: Sendable {
    public let client: GitClient

    public init(client: GitClient) {
        self.client = client
    }

    public func inspect() async throws -> RepositoryInfo {
        let path = client.repositoryURL.path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            throw SyncFailure(kind: .folderMissing, stage: .inspect, message: String(localized: "本地文件夹不存在或已被移动：\(path)"))
        }
        guard FileManager.default.isReadableFile(atPath: path) else {
            throw SyncFailure(kind: .permissionDenied, stage: .inspect, message: String(localized: "没有读取该文件夹的权限：\(path)"))
        }

        let top = try await git(["rev-parse", "--show-toplevel"])
        guard top.succeeded else {
            var failure = SyncFailure.from(top, stage: .inspect, command: "git rev-parse --show-toplevel")
            if failure.kind == .unknown || failure.kind == .notARepository {
                failure = SyncFailure(
                    kind: .notARepository, stage: .inspect, command: failure.command,
                    exitCode: failure.exitCode, stderr: failure.stderr,
                    message: String(localized: "所选文件夹不是 Git 仓库：\(path)")
                )
            }
            throw failure
        }
        let topLevel = top.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let gitDir = try await git(["rev-parse", "--absolute-git-dir"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let branchResult = try await git(["symbolic-ref", "--quiet", "--short", "HEAD"])
        let branch = branchResult.succeeded
            ? branchResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil

        let isUnborn = !(try await git(["rev-parse", "--verify", "--quiet", "HEAD"]).succeeded)

        let remote = try await git(["remote", "get-url", "origin"])
        let remoteURL = remote.succeeded ? remote.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil

        let upstream = try await resolveUpstream(branch: branch)

        var ahead = 0, behind = 0
        if let upstream, !isUnborn {
            (ahead, behind) = try await aheadBehind(upstream: upstream)
        }

        let status = try await git(["status", "--porcelain=v1", "-z", "--untracked-files=all"], timeout: 120)
        let entries = status.succeeded ? StatusEntry.parse(status.stdoutData) : []

        let unmerged = try await unmergedPaths()

        return RepositoryInfo(
            topLevelPath: topLevel,
            gitDirectory: gitDir,
            branch: branch,
            isUnborn: isUnborn,
            remoteURL: remoteURL,
            upstream: upstream,
            ahead: ahead,
            behind: behind,
            changedFiles: entries.count,
            inProgressOperation: Self.inProgressOperation(gitDirectory: gitDir),
            unmergedFiles: unmerged,
            indexLocked: FileManager.default.fileExists(atPath: gitDir + "/index.lock")
        )
    }

    /// "origin/main" style name of the branch to integrate with, or nil if the remote
    /// branch does not exist yet.
    public func resolveUpstream(branch: String?) async throws -> String? {
        let configured = try await git(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"])
        if configured.succeeded {
            let name = configured.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            // Confirm the tracking ref really exists (it may have been pruned).
            if try await git(["rev-parse", "--verify", "--quiet", "refs/remotes/\(name)"]).succeeded {
                return name
            }
        }
        guard let branch else { return nil }
        if try await git(["rev-parse", "--verify", "--quiet", "refs/remotes/origin/\(branch)"]).succeeded {
            return "origin/\(branch)"
        }
        return nil
    }

    /// The branch GitHub shows by default ("origin/main" style): the fetched remote HEAD, else
    /// main or master, else the remote's only branch. Nil when there is nothing to choose.
    public func remoteDefaultBranch() async throws -> String? {
        let head = try await git(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"])
        if head.succeeded {
            let name = head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if try await git(["rev-parse", "--verify", "--quiet", "refs/remotes/\(name)"]).succeeded {
                return name
            }
        }
        let refs = try await git(["for-each-ref", "--format=%(refname)", "refs/remotes/origin/"])
        guard refs.succeeded else { return nil }
        let names = refs.stdout.split(separator: "\n")
            .map { String($0.dropFirst("refs/remotes/".count)) }
            .filter { $0 != "origin/HEAD" }
        for preferred in ["origin/main", "origin/master"] where names.contains(preferred) {
            return preferred
        }
        return names.count == 1 ? names[0] : nil
    }

    /// True when GitHub has commits the last fetch didn't bring: one small `ls-remote` request, no
    /// download. False when nothing changed, the branch has no upstream yet, or GitHub can't be reached.
    public func remoteHasNewCommits(timeout: TimeInterval = 15) async -> Bool {
        guard let branchResult = try? await git(["symbolic-ref", "--quiet", "--short", "HEAD"]), branchResult.succeeded,
              let upstream = try? await resolveUpstream(branch: branchResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return false }
        let slash = upstream.firstIndex(of: "/") ?? upstream.endIndex
        let remote = String(upstream[..<slash])
        let remoteBranch = slash == upstream.endIndex ? upstream : String(upstream[upstream.index(after: slash)...])
        guard let listed = try? await client.run(["ls-remote", remote, "refs/heads/\(remoteBranch)"], timeout: timeout),
              listed.succeeded,
              let remoteHead = listed.stdout.split(whereSeparator: { $0 == "\t" || $0 == "\n" }).first.map(String.init),
              let local = try? await git(["rev-parse", "--verify", "--quiet", "refs/remotes/\(upstream)"]), local.succeeded
        else { return false }
        return remoteHead != local.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func aheadBehind(upstream: String) async throws -> (ahead: Int, behind: Int) {
        let result = try await git(["rev-list", "--left-right", "--count", "HEAD...\(upstream)"])
        guard result.succeeded else { return (0, 0) }
        let numbers = result.stdout.split(whereSeparator: { $0 == "\t" || $0 == " " || $0 == "\n" })
            .compactMap { Int($0) }
        guard numbers.count == 2 else { return (0, 0) }
        return (numbers[0], numbers[1])
    }

    public func unmergedPaths() async throws -> [String] {
        let result = try await git(["diff", "--name-only", "--diff-filter=U", "-z"])
        guard result.succeeded else { return [] }
        return result.stdoutData.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }

    public static func inProgressOperation(gitDirectory: String) -> InProgressOperation? {
        let fm = FileManager.default
        if fm.fileExists(atPath: gitDirectory + "/rebase-merge") || fm.fileExists(atPath: gitDirectory + "/rebase-apply") {
            return .rebase
        }
        if fm.fileExists(atPath: gitDirectory + "/MERGE_HEAD") { return .merge }
        if fm.fileExists(atPath: gitDirectory + "/CHERRY_PICK_HEAD") { return .cherryPick }
        if fm.fileExists(atPath: gitDirectory + "/REVERT_HEAD") { return .revert }
        return nil
    }

    private func git(_ args: [String], timeout: TimeInterval = 30) async throws -> ProcessResult {
        do {
            return try await client.run(args, timeout: timeout)
        } catch {
            throw SyncFailure(
                kind: .gitUnavailable, stage: .inspect, command: "git " + args.joined(separator: " "),
                stderr: error.localizedDescription
            )
        }
    }
}
