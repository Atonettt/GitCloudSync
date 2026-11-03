import Foundation
import XCTest

final class RepositoryCreatorTests: XCTestCase {
    private var sandbox: GitSandbox!

    override func setUp() async throws {
        sandbox = try GitSandbox(git: try await GitSandbox.makeGit())
    }

    override func tearDown() async throws {
        sandbox = nil
    }

    private var creator: RepositoryCreator { RepositoryCreator(git: sandbox.git) }

    private func makeFolder(_ name: String, files: [String: String] = [:]) throws -> URL {
        let url = sandbox.root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for (path, content) in files { try sandbox.write(content, to: path, in: url) }
        return url
    }

    private func preview(_ folder: URL, limit: Int64 = 1_000_000) async throws -> FolderPreview {
        try await creator.preview(folder: folder, largeFileLimit: limit, ignorePatterns: IgnoreRules.defaultPatterns)
    }

    // MARK: Naming

    func testSuggestedNames() {
        XCTAssertEqual(RepositoryNaming.suggestedName(for: "research-notes"), "research-notes")
        XCTAssertEqual(RepositoryNaming.suggestedName(for: "My Thesis 2026"), "My-Thesis-2026")
        XCTAssertEqual(RepositoryNaming.suggestedName(for: "论文 draft v2"), "draft-v2")
        XCTAssertEqual(RepositoryNaming.suggestedName(for: "研究资料"), "")
        XCTAssertEqual(RepositoryNaming.suggestedName(for: "notes.git"), "notes")
        XCTAssertEqual(RepositoryNaming.suggestedName(for: String(repeating: "a", count: 150)).count, 100)
    }

    func testNameValidation() {
        XCTAssertNil(RepositoryNaming.problem(with: "my_repo.v2"))
        XCTAssertNotNil(RepositoryNaming.problem(with: ""))
        XCTAssertNotNil(RepositoryNaming.problem(with: "研究资料"))
        XCTAssertNotNil(RepositoryNaming.problem(with: "has space"))
        XCTAssertNotNil(RepositoryNaming.problem(with: ".."))
        XCTAssertNotNil(RepositoryNaming.problem(with: "x.git"))
    }

    func testSystemFoldersAreRefused() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertNotNil(RepositoryCreator.refusalReason(for: home))
        XCTAssertNotNil(RepositoryCreator.refusalReason(for: home.appendingPathComponent("Desktop")))
        XCTAssertNotNil(RepositoryCreator.refusalReason(for: URL(fileURLWithPath: "/")))
        XCTAssertNil(RepositoryCreator.refusalReason(for: home.appendingPathComponent("Desktop/研究资料")))
    }

    // MARK: Preview

    func testPreviewOfPlainFolderCountsFilesAndSkipsJunk() async throws {
        let folder = try makeFolder("资料", files: ["a.txt": "12345", "sub/b.txt": "123", ".DS_Store": "junk", "~$报告.docx": "lock"])
        try sandbox.writeData(Data(count: 2_000), to: "big.bin", in: folder)

        let result = try await preview(folder, limit: 1_000)

        XCTAssertEqual(result.kind, .plainFolder)
        XCTAssertEqual(result.fileCount, 3)
        XCTAssertEqual(result.totalBytes, 2_008)
        XCTAssertEqual(result.oversized.map(\.path), ["big.bin"])
        XCTAssertFalse(result.truncated)
    }

    func testPreviewRecognisesRepositories() async throws {
        let local = try makeFolder("local", files: ["a.txt": "a"])
        try await sandbox.run(["init", "-q", "-b", "main"], in: local)
        try await sandbox.configure(local)
        try await sandbox.run(["add", "-A"], in: local)
        try await sandbox.run(["commit", "-qm", "one"], in: local)
        let localPreview = try await preview(local)
        XCTAssertEqual(localPreview.kind, .repositoryWithoutRemote(commits: 1))

        let nested = try makeFolder("local/sub")
        let nestedPreview = try await preview(nested)
        XCTAssertEqual(nestedPreview.kind, .insideRepository(root: RepositoryCreator.canonicalPath(local.path)))

        try await sandbox.createRemote()
        let clone = try await sandbox.clone("clone")
        guard case .linkedRepository = try await preview(clone).kind else {
            return XCTFail("a clone is already linked")
        }
    }

    // MARK: Prepare + first sync

    func testPlainFolderBecomesRepositoryAndFirstSyncUploadsEverything() async throws {
        try await sandbox.createEmptyRemote()
        let folder = try makeFolder("研究资料", files: ["笔记.md": "hello", "图片/a.txt": "a", ".DS_Store": "junk"])
        let identity = GitIdentity(name: "Octo", email: "1+octo@users.noreply.github.com")

        let created = try await creator.prepare(folder: folder, remoteURL: sandbox.bare.path, identity: identity,
                                                ignorePatterns: IgnoreRules.defaultPatterns)
        XCTAssertTrue(created)

        let report = await sandbox.engine(for: folder).sync()

        XCTAssertEqual(report.summary?.committedFiles, 2, report.debugText)
        XCTAssertEqual(report.info?.branch, "main")
        XCTAssertEqual(report.info?.upstream, "origin/main")
        let remoteFiles = try await sandbox.remoteFiles()
        XCTAssertEqual(Set(remoteFiles), ["笔记.md", "图片/a.txt"])
        let email = try await sandbox.run(["log", "-1", "--format=%ae", "main"], in: sandbox.bare).stdout
        XCTAssertEqual(email.trimmingCharacters(in: .whitespacesAndNewlines), identity.email,
                       "commits use the GitHub noreply address, not the global git email")
    }

    func testExistingLocalRepositoryKeepsHistoryAndIdentity() async throws {
        try await sandbox.createEmptyRemote()
        let folder = try makeFolder("local", files: ["a.txt": "a"])
        try await sandbox.run(["init", "-q", "-b", "main"], in: folder)
        try await sandbox.configure(folder)
        try await sandbox.run(["add", "-A"], in: folder)
        try await sandbox.run(["commit", "-qm", "earlier work"], in: folder)

        let created = try await creator.prepare(folder: folder, remoteURL: sandbox.bare.path,
                                                identity: GitIdentity(name: "Octo", email: "octo@noreply"),
                                                ignorePatterns: IgnoreRules.defaultPatterns)
        XCTAssertFalse(created)
        let email = try await sandbox.run(["config", "--local", "user.email"], in: folder).stdout
        XCTAssertEqual(email.trimmingCharacters(in: .whitespacesAndNewlines), "tester@example.com", "an existing identity is kept")

        let report = await sandbox.engine(for: folder).sync()
        XCTAssertEqual(report.summary?.uploadedCommits, 1, report.debugText)
        let log = try await sandbox.run(["log", "--format=%s", "main"], in: sandbox.bare).stdout
        XCTAssertEqual(log.trimmingCharacters(in: .whitespacesAndNewlines), "earlier work")
    }

    func testPrepareRefusesNestedFolderAndForeignRemote() async throws {
        let parent = try makeFolder("parent", files: ["a.txt": "a"])
        try await sandbox.run(["init", "-q", "-b", "main"], in: parent)
        let child = try makeFolder("parent/child")
        do {
            try await creator.prepare(folder: child, remoteURL: "https://example.invalid/x.git", identity: nil, ignorePatterns: [])
            XCTFail("nested folder must be refused")
        } catch {}
        XCTAssertFalse(sandbox.exists(".git", in: child))
        let parentRemotes = try await sandbox.run(["remote"], in: parent).stdout
        XCTAssertTrue(parentRemotes.isEmpty, "the parent repository is untouched")

        try await sandbox.run(["remote", "add", "origin", "https://example.invalid/other.git"], in: parent)
        do {
            try await creator.prepare(folder: parent, remoteURL: "https://example.invalid/new.git", identity: nil, ignorePatterns: [])
            XCTFail("an existing different origin must not be replaced")
        } catch {}
        let origin = try await sandbox.run(["remote", "get-url", "origin"], in: parent).stdout
        XCTAssertEqual(origin.trimmingCharacters(in: .whitespacesAndNewlines), "https://example.invalid/other.git")
    }

    func testRemoteIsEmpty() async throws {
        try await sandbox.createEmptyRemote()
        let folder = try makeFolder("plain")
        let empty = try await creator.remoteIsEmpty(sandbox.bare.path, credential: nil, in: folder)
        XCTAssertTrue(empty)

        let seed = try await sandbox.clone("seed")
        try await sandbox.commitAndPushInitial(["a.txt": "a"], in: seed)
        let nonEmpty = try await creator.remoteIsEmpty(sandbox.bare.path, credential: nil, in: folder)
        XCTAssertFalse(nonEmpty)
    }
}

private extension GitSandbox {
    /// First push to an empty remote (the regular helper pulls first, which fails on an empty remote).
    func commitAndPushInitial(_ files: [String: String], in repo: URL) async throws {
        for (name, content) in files { try write(content, to: name, in: repo) }
        try await run(["add", "-A"], in: repo)
        try await run(["commit", "-m", "initial"], in: repo)
        try await run(["push", "-u", "origin", "HEAD:main"], in: repo)
    }
}
