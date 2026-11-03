import Foundation
import XCTest

final class RepositoryRemovalTests: XCTestCase {
    private var sandbox: GitSandbox!

    override func setUp() async throws {
        sandbox = try GitSandbox(git: try await GitSandbox.makeGit())
    }

    override func tearDown() async throws {
        sandbox = nil
    }

    private func removal(_ repo: URL) -> RepositoryRemoval {
        RepositoryRemoval(client: GitClient(repositoryURL: repo, git: sandbox.git))
    }

    func testCheckCountsWorkOnEachSide() async throws {
        try await sandbox.createRemote()
        let mac = try await sandbox.clone("mac")
        let other = try await sandbox.clone("other")
        try await sandbox.commitAndPush(["from-other.txt": "x"], in: other)
        try sandbox.write("committed", to: "a.txt", in: mac)
        try await sandbox.run(["add", "-A"], in: mac)
        try await sandbox.run(["commit", "-qm", "local only"], in: mac)
        try sandbox.write("dirty", to: "b.txt", in: mac)

        let local = try await removal(mac).check(fetch: false)
        XCTAssertEqual(local, DeletionCheck(uncommittedFiles: 1, unpushedCommits: 1, remoteOnlyCommits: nil))
        XCTAssertTrue(local.hasLocalOnlyWork)

        let both = try await removal(mac).check(fetch: true)
        XCTAssertEqual(both.remoteOnlyCommits, 1, "the other Mac's commit is only on GitHub")
        XCTAssertEqual(sandbox.read("from-other.txt", in: mac), nil, "checking never merges")
    }

    func testFullySyncedRepositoryHasNothingToLose() async throws {
        try await sandbox.createRemote()
        let mac = try await sandbox.clone("mac")
        let check = try await removal(mac).check(fetch: true)
        XCTAssertEqual(check, DeletionCheck(uncommittedFiles: 0, unpushedCommits: 0, remoteOnlyCommits: 0))
        XCTAssertFalse(check.hasLocalOnlyWork)
    }

    func testDetachAfterGitHubDeletionKeepsHistoryAndAllowsRepublishing() async throws {
        try await sandbox.createRemote()
        let mac = try await sandbox.clone("mac")
        let other = try await sandbox.clone("other")
        try await sandbox.commitAndPush(["from-other.txt": "x"], in: other)
        _ = try await removal(mac).check(fetch: true)   // downloaded but not merged

        let renamed = try await removal(mac).detachDeletedRemote()

        let info = try await RepositoryInspector(client: GitClient(repositoryURL: mac, git: sandbox.git)).inspect()
        XCTAssertNil(info.remoteURL)
        XCTAssertNil(info.upstream)
        XCTAssertEqual(sandbox.read("README.md", in: mac), "hello\n", "files are untouched")
        let kept = try await sandbox.run(["rev-parse", "--verify", "refs/remotes/\(renamed)/main"], in: mac)
        XCTAssertTrue(kept.succeeded, "downloaded commits stay reachable under the renamed remote")

        // Sync now fails clearly instead of pushing anywhere.
        let failed = await sandbox.engine(for: mac).sync()
        XCTAssertEqual(failed.failure?.kind, .noRemote, failed.debugText)

        // Publish again to a new, empty "GitHub" repository.
        let newRemote = sandbox.root.appendingPathComponent("new.git")
        try await sandbox.run(["init", "--bare", "-q", "-b", "main", newRemote.path], in: sandbox.root)
        try await RepositoryCreator(git: sandbox.git).prepare(folder: mac, remoteURL: newRemote.path, identity: nil,
                                                              ignorePatterns: IgnoreRules.defaultPatterns)
        let report = await sandbox.engine(for: mac).sync()
        XCTAssertNotNil(report.summary, report.debugText)
        XCTAssertEqual(report.info?.upstream, "origin/main")
        let log = try await sandbox.run(["log", "--format=%s", "main"], in: newRemote).stdout
        XCTAssertTrue(log.contains("initial"), "the full history is uploaded to the new repository")
    }

    func testGitHubNameParsing() {
        XCTAssertEqual(RepositoryRemoval.gitHubFullName(fromRemote: "https://github.com/Atonettt/MacGit.git")?.name, "MacGit")
        XCTAssertEqual(RepositoryRemoval.gitHubFullName(fromRemote: "git@github.com:Atonettt/MacGit.git")?.owner, "Atonettt")
        XCTAssertEqual(RepositoryRemoval.gitHubFullName(fromRemote: "https://x-access-token@github.com/a/b")?.name, "b")
        XCTAssertNil(RepositoryRemoval.gitHubFullName(fromRemote: "https://gitlab.com/a/b.git"))
        XCTAssertNil(RepositoryRemoval.gitHubFullName(fromRemote: "/tmp/remote.git"))
        XCTAssertNil(RepositoryRemoval.gitHubFullName(fromRemote: "https://github.com/a/b/c"))
    }

    func testRepositoryNotFoundIsNotShownAsSignInProblem() {
        let failure = SyncFailure(kind: .repositoryNotFound, stage: .fetch)
        XCTAssertEqual(failure.mappedStatus, .failed)
        XCTAssertTrue(failure.message.contains("删除"))
    }
}
