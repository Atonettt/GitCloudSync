import Foundation
import XCTest

/// Temporary bare "GitHub" repository plus clones standing in for two Macs.
final class GitSandbox {
    let root: URL
    let bare: URL
    let git: GitEnvironment

    init(git: GitEnvironment) throws {
        self.git = git
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitCloudSyncTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        bare = root.appendingPathComponent("remote.git")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    static func makeGit() async throws -> GitEnvironment {
        switch await GitEnvironment.detect() {
        case .success(let env): return env
        case .failure(let error): throw error
        }
    }

    /// Creates the bare remote with one initial commit on `main`.
    func createRemote(seedFiles: [String: String] = ["README.md": "hello\n"]) async throws {
        try await run(["init", "--bare", "-b", "main", bare.path], in: root)
        let seed = root.appendingPathComponent("seed")
        try await run(["clone", bare.path, seed.path], in: root)
        try await configure(seed)
        for (name, content) in seedFiles { try write(content, to: name, in: seed) }
        try await run(["add", "-A"], in: seed)
        try await run(["commit", "-m", "initial"], in: seed)
        try await run(["push", "-u", "origin", "main"], in: seed)
    }

    func createEmptyRemote() async throws {
        try await run(["init", "--bare", "-b", "main", bare.path], in: root)
    }

    func clone(_ name: String) async throws -> URL {
        let url = root.appendingPathComponent(name)
        try await run(["clone", bare.path, url.path], in: root)
        try await configure(url)
        return url
    }

    func configure(_ repo: URL) async throws {
        try await run(["config", "user.name", "Tester"], in: repo)
        try await run(["config", "user.email", "tester@example.com"], in: repo)
        try await run(["config", "commit.gpgsign", "false"], in: repo)
    }

    func engine(for repo: URL, options: SyncOptions = SyncOptions()) -> SyncEngine {
        SyncEngine(client: GitClient(repositoryURL: repo, git: git), options: options)
    }

    @discardableResult
    func run(_ args: [String], in dir: URL) async throws -> ProcessResult {
        var env = git.environment
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        let result = try await ProcessRunner.run(executable: git.gitURL, arguments: ["-c", "core.quotepath=false"] + args, currentDirectory: dir,
                                                 environment: env, timeout: 60)
        guard result.succeeded else {
            throw NSError(domain: "GitSandbox", code: Int(result.exitCode), userInfo: [
                NSLocalizedDescriptionKey: "git \(args.joined(separator: " ")) failed: \(result.stderr)",
            ])
        }
        return result
    }

    func write(_ content: String, to name: String, in repo: URL) throws {
        let url = repo.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    func writeData(_ data: Data, to name: String, in repo: URL) throws {
        let url = repo.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    func read(_ name: String, in repo: URL) -> String? {
        try? String(contentsOf: repo.appendingPathComponent(name), encoding: .utf8)
    }

    func exists(_ name: String, in repo: URL) -> Bool {
        FileManager.default.fileExists(atPath: repo.appendingPathComponent(name).path)
    }

    /// Commit and push directly with git, simulating the other Mac / GitHub Desktop.
    func commitAndPush(_ files: [String: String], in repo: URL, message: String = "remote change") async throws {
        try await run(["pull", "--ff-only"], in: repo)
        for (name, content) in files { try write(content, to: name, in: repo) }
        try await run(["add", "-A"], in: repo)
        try await run(["commit", "-m", message], in: repo)
        try await run(["push"], in: repo)
    }

    func remoteFiles() async throws -> [String] {
        let result = try await run(["ls-tree", "-r", "--name-only", "main"], in: bare)
        return result.stdout.split(separator: "\n").map(String.init)
    }

    func remoteContent(_ path: String) async throws -> String {
        try await run(["show", "main:\(path)"], in: bare).stdout
    }
}

extension SyncReport {
    var summary: SyncSummary? {
        if case .success(let summary) = outcome { return summary }
        return nil
    }

    var failure: SyncFailure? {
        if case .failure(let failure) = outcome { return failure }
        return nil
    }

    var conflicts: [ConflictFile]? {
        if case .conflict(let files) = outcome { return files }
        return nil
    }

    var isNoChanges: Bool {
        if case .noChanges = outcome { return true }
        return false
    }

    var debugText: String {
        "\(outcome)\n" + steps.map { $0.line + "\n" + $0.output }.joined(separator: "\n")
    }
}
