import Foundation
import XCTest

final class SyncEngineTests: XCTestCase {
    private var sandbox: GitSandbox!

    override func setUp() async throws {
        sandbox = try GitSandbox(git: try await GitSandbox.makeGit())
    }

    override func tearDown() async throws {
        sandbox = nil
    }

    // MARK: Upload / download

    func testFirstUploadToEmptyRemotePublishesBranch() async throws {
        try await sandbox.createEmptyRemote()
        let mac = try await sandbox.clone("mac")
        try sandbox.write("报告.docx-binary", to: "文档/报告.docx", in: mac)

        let report = await sandbox.engine(for: mac).sync()

        XCTAssertNotNil(report.summary, report.debugText)
        XCTAssertEqual(report.summary?.committedFiles, 1)
        let remoteFiles = try await sandbox.remoteFiles()
        XCTAssertEqual(remoteFiles, ["文档/报告.docx"])
        XCTAssertEqual(report.info?.upstream, "origin/main", "upstream should be configured after first push")
    }

    func testLocalChangesAreUploaded() async throws {
        try await sandbox.createRemote()
        let mac = try await sandbox.clone("mac")
        try sandbox.write("new content", to: "notes.txt", in: mac)
        try sandbox.write("changed\n", to: "README.md", in: mac)

        let report = await sandbox.engine(for: mac).sync()

        XCTAssertEqual(report.summary?.committedFiles, 2, report.debugText)
        XCTAssertEqual(report.summary?.uploadedCommits, 1)
        let notes = try await sandbox.remoteContent("notes.txt")
        XCTAssertEqual(notes, "new content")
        XCTAssertEqual(report.info?.changedFiles, 0)
        XCTAssertEqual(report.info?.ahead, 0)
    }

    func testRemoteChangesAreDownloaded() async throws {
        try await sandbox.createRemote()
        let mac = try await sandbox.clone("mac")
        let other = try await sandbox.clone("other")
        try await sandbox.commitAndPush(["from-other.txt": "hi from other mac"], in: other)

        let report = await sandbox.engine(for: mac).sync()

        XCTAssertEqual(report.summary?.downloadedCommits, 1, report.debugText)
        XCTAssertEqual(sandbox.read("from-other.txt", in: mac), "hi from other mac")
    }

    func testNoChangesReportsNoChanges() async throws {
        try await sandbox.createRemote()
        let mac = try await sandbox.clone("mac")
        let report = await sandbox.engine(for: mac).sync()
        XCTAssertTrue(report.isNoChanges, report.debugText)
        XCTAssertEqual(report.status, .noChanges)
    }

    /// An empty folder linked to a GitHub repository that later got content on another branch
    /// (e.g. pushed by a web tool): the content is downloaded and the branch is followed.
    func testEmptyRepositoryAdoptsGitHubDefaultBranch() async throws {
        let local = try await makeEmptyLocalWithRemoteBranch("feature", files: ["a.txt": "from GitHub\n"])
        try sandbox.write("mine\n", to: "mine.txt", in: local)

        let report = await sandbox.engine(for: local).sync()

        XCTAssertEqual(report.summary?.downloadedCommits, 1, report.debugText)
        XCTAssertEqual(report.summary?.committedFiles, 1)
        XCTAssertEqual(report.info?.branch, "feature")
        XCTAssertEqual(report.info?.upstream, "origin/feature")
        XCTAssertEqual(sandbox.read("a.txt", in: local), "from GitHub\n")
        let remote = try await sandbox.run(["ls-tree", "-r", "--name-only", "feature"], in: sandbox.bare).stdout
        XCTAssertEqual(Set(remote.split(separator: "\n").map(String.init)), ["a.txt", "mine.txt"])

        let again = await sandbox.engine(for: local).sync()
        XCTAssertTrue(again.isNoChanges, again.debugText)
    }

    func testEmptyRepositoryDownloadsSameNamedBranch() async throws {
        let local = try await makeEmptyLocalWithRemoteBranch("main", files: ["a.txt": "a\n"])
        let report = await sandbox.engine(for: local).sync()
        XCTAssertEqual(report.summary?.downloadedCommits, 1, report.debugText)
        XCTAssertEqual(report.info?.upstream, "origin/main")
        XCTAssertEqual(sandbox.read("a.txt", in: local), "a\n")
    }

    func testEmptyRepositoryNeverOverwritesClashingLocalFile() async throws {
        let local = try await makeEmptyLocalWithRemoteBranch("feature", files: ["a.txt": "from GitHub\n"])
        try sandbox.write("local version\n", to: "a.txt", in: local)

        let report = await sandbox.engine(for: local).sync()

        XCTAssertEqual(report.failure?.kind, .unbornWithRemote, report.debugText)
        XCTAssertEqual(sandbox.read("a.txt", in: local), "local version\n")
    }

    /// GitHub has `files` on `branch` (its default); the local folder is a fresh `git init -b main`
    /// pointing at it, like a folder GitSync linked while the repository was still empty.
    private func makeEmptyLocalWithRemoteBranch(_ branch: String, files: [String: String]) async throws -> URL {
        try await sandbox.createEmptyRemote()
        let seed = try await sandbox.clone("seed")
        for (name, content) in files { try sandbox.write(content, to: name, in: seed) }
        try await sandbox.run(["add", "-A"], in: seed)
        try await sandbox.run(["commit", "-qm", "work"], in: seed)
        try await sandbox.run(["push", "-q", "origin", "HEAD:\(branch)"], in: seed)
        try await sandbox.run(["symbolic-ref", "HEAD", "refs/heads/\(branch)"], in: sandbox.bare)

        let local = sandbox.root.appendingPathComponent("local")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try await sandbox.run(["init", "-q", "-b", "main"], in: local)
        try await sandbox.configure(local)
        try await sandbox.run(["remote", "add", "origin", sandbox.bare.path], in: local)
        return local
    }

    // MARK: Revert to the GitHub version

    func testRevertToRemoteUndoesUnsyncedEditsAndDeletions() async throws {
        try await sandbox.createRemote(seedFiles: ["docs/a.txt": "a\n", "docs/b.txt": "b\n", "c.txt": "c\n"])
        let mac = try await sandbox.clone("mac")
        try sandbox.write("broken\n", to: "docs/a.txt", in: mac)
        try FileManager.default.removeItem(at: mac.appendingPathComponent("docs/b.txt"))
        try sandbox.write("new\n", to: "docs/new.txt", in: mac)
        try sandbox.write("c edited\n", to: "c.txt", in: mac)

        let report = await sandbox.engine(for: mac).revertToRemote(paths: ["docs"])

        XCTAssertEqual(report.summary?.restoredFiles, 2, report.debugText)
        XCTAssertEqual(sandbox.read("docs/a.txt", in: mac), "a\n")
        XCTAssertEqual(sandbox.read("docs/b.txt", in: mac), "b\n")
        XCTAssertEqual(sandbox.read("docs/new.txt", in: mac), "new\n", "a file only on this Mac is kept")
        XCTAssertEqual(sandbox.read("c.txt", in: mac), "c edited\n", "files outside the folder are untouched")
        let log = try await sandbox.run(["log", "--oneline", "origin/main"], in: mac).stdout
        XCTAssertEqual(log.split(separator: "\n").count, 1, "nothing was uploaded")

        let backups = try await sandbox.run(["for-each-ref", "--format=%(refname)", "refs/gitcloud-sync/backup/"], in: mac).stdout
        let ref = try XCTUnwrap(backups.split(separator: "\n").first.map(String.init))
        let saved = try await sandbox.run(["show", "\(ref):docs/a.txt"], in: mac).stdout
        XCTAssertEqual(saved, "broken\n", "the discarded edit is kept in the backup")
    }

    func testRevertToRemoteUsesNewestGitHubVersion() async throws {
        try await sandbox.createRemote(seedFiles: ["a.txt": "v1\n"])
        let mac = try await sandbox.clone("mac")
        let other = try await sandbox.clone("other")
        try await sandbox.commitAndPush(["a.txt": "v2 from the other Mac\n"], in: other)
        try FileManager.default.removeItem(at: mac.appendingPathComponent("a.txt"))

        let report = await sandbox.engine(for: mac).revertToRemote(paths: ["a.txt"])

        XCTAssertEqual(report.summary?.restoredFiles, 1, report.debugText)
        XCTAssertEqual(sandbox.read("a.txt", in: mac), "v2 from the other Mac\n")
        let next = await sandbox.engine(for: mac).sync()
        XCTAssertNil(next.failure, next.debugText)
        XCTAssertEqual(sandbox.read("a.txt", in: mac), "v2 from the other Mac\n")
        let remote = try await sandbox.remoteContent("a.txt")
        XCTAssertEqual(remote, "v2 from the other Mac\n")
    }

    func testRevertToRemoteWithNothingToUndo() async throws {
        try await sandbox.createRemote()
        let mac = try await sandbox.clone("mac")
        try sandbox.write("only here\n", to: "local.txt", in: mac)
        let report = await sandbox.engine(for: mac).revertToRemote(paths: ["README.md", "local.txt"])
        XCTAssertTrue(report.isNoChanges, report.debugText)
        XCTAssertEqual(sandbox.read("local.txt", in: mac), "only here\n")
    }

    func testReportListsDownloadedFiles() async throws {
        try await sandbox.createRemote(seedFiles: ["a.txt": "a\n", "b.txt": "b\n"])
        let mac = try await sandbox.clone("mac")
        let other = try await sandbox.clone("other")
        try await sandbox.commitAndPush(["b.txt": "b changed\n", "new/c.txt": "c\n"], in: other)
        try sandbox.write("a local\n", to: "a.txt", in: mac)

        let report = await sandbox.engine(for: mac).sync()

        XCTAssertNotNil(report.summary, report.debugText)
        XCTAssertEqual(Set(report.downloadedFiles), ["b.txt", "new/c.txt"], "local edits are not counted as downloads")
        let again = await sandbox.engine(for: mac).sync()
        XCTAssertEqual(again.downloadedFiles, [])
    }

    func testRemoteHasNewCommitsDetectsPushesWithoutFetching() async throws {
        try await sandbox.createRemote()
        let mac = try await sandbox.clone("mac")
        let other = try await sandbox.clone("other")
        let inspector = RepositoryInspector(client: GitClient(repositoryURL: mac, git: sandbox.git))

        let before = await inspector.remoteHasNewCommits()
        XCTAssertFalse(before)
        try await sandbox.commitAndPush(["a.txt": "from the cloud\n"], in: other)
        let after = await inspector.remoteHasNewCommits()
        XCTAssertTrue(after)
        XCTAssertFalse(sandbox.exists("a.txt", in: mac), "the check downloads nothing")

        _ = await sandbox.engine(for: mac).sync()
        let synced = await inspector.remoteHasNewCommits()
        XCTAssertFalse(synced)
    }

    func testNonConflictingChangesOnBothSidesAreMerged() async throws {
        try await sandbox.createRemote(seedFiles: ["a.txt": "a\n", "b.txt": "b\n"])
        let mac = try await sandbox.clone("mac")
        let other = try await sandbox.clone("other")
        try await sandbox.commitAndPush(["b.txt": "b changed remotely\n"], in: other)
        try sandbox.write("a changed locally\n", to: "a.txt", in: mac)

        let report = await sandbox.engine(for: mac).sync()

        XCTAssertNotNil(report.summary, report.debugText)
        XCTAssertEqual(sandbox.read("a.txt", in: mac), "a changed locally\n")
        XCTAssertEqual(sandbox.read("b.txt", in: mac), "b changed remotely\n")
        let remoteA = try await sandbox.remoteContent("a.txt")
        XCTAssertEqual(remoteA, "a changed locally\n")
        XCTAssertEqual(report.info?.ahead, 0)
        XCTAssertEqual(report.info?.behind, 0)
    }

    // MARK: Conflicts

    func testSameFileConflictIsDetectedAndNothingIsOverwritten() async throws {
        try await sandbox.createRemote(seedFiles: ["合同.docx": "v1"])
        let mac = try await sandbox.clone("mac")
        let other = try await sandbox.clone("other")
        try await sandbox.commitAndPush(["合同.docx": "edited on other mac"], in: other)
        try sandbox.write("edited on this mac", to: "合同.docx", in: mac)

        let report = await sandbox.engine(for: mac).sync()

        XCTAssertEqual(report.conflicts?.map(\.path), ["合同.docx"], report.debugText)
        XCTAssertEqual(report.status, .conflict)
        // Local version stays on disk, merge was aborted, remote untouched.
        XCTAssertEqual(sandbox.read("合同.docx", in: mac), "edited on this mac")
        XCTAssertNil(report.info?.inProgressOperation)
        XCTAssertEqual(report.info?.unmergedFiles, [])
        XCTAssertEqual(report.info?.ahead, 1, "local edit must be preserved as a commit")
        let remote = try await sandbox.remoteContent("合同.docx")
        XCTAssertEqual(remote, "edited on other mac")

        // A second sync detects the same conflict again rather than doing anything destructive.
        let again = await sandbox.engine(for: mac).sync()
        XCTAssertEqual(again.conflicts?.map(\.path), ["合同.docx"])
        XCTAssertEqual(sandbox.read("合同.docx", in: mac), "edited on this mac")
    }

    func testResolveConflictKeepBothSavesRemoteCopyAndPushes() async throws {
        try await sandbox.createRemote(seedFiles: ["plan.xlsx": "v1"])
        let mac = try await sandbox.clone("mac")
        let other = try await sandbox.clone("other")
        try await sandbox.commitAndPush(["plan.xlsx": "remote"], in: other)
        try sandbox.write("local", to: "plan.xlsx", in: mac)
        _ = await sandbox.engine(for: mac).sync()

        let report = await sandbox.engine(for: mac).resolveConflicts(choices: ["plan.xlsx": .keepBoth])

        XCTAssertNotNil(report.summary, report.debugText)
        XCTAssertEqual(sandbox.read("plan.xlsx", in: mac), "local")
        let files = try FileManager.default.contentsOfDirectory(atPath: mac.path)
        let copy = try XCTUnwrap(files.first { $0.hasPrefix("plan (远程版本") && $0.hasSuffix(".xlsx") })
        XCTAssertEqual(sandbox.read(copy, in: mac), "remote")
        let remoteFiles = try await sandbox.remoteFiles()
        XCTAssertTrue(remoteFiles.contains(copy))
        let remotePlan = try await sandbox.remoteContent("plan.xlsx")
        XCTAssertEqual(remotePlan, "local")
        // Backup ref exists.
        let refs = try await sandbox.run(["for-each-ref", "refs/gitcloud-sync/backup"], in: mac).stdout
        XCTAssertFalse(refs.isEmpty)
    }

    func testResolveConflictKeepRemote() async throws {
        try await sandbox.createRemote(seedFiles: ["photo.jpg": "v1"])
        let mac = try await sandbox.clone("mac")
        let other = try await sandbox.clone("other")
        try await sandbox.commitAndPush(["photo.jpg": "remote"], in: other)
        try sandbox.write("local", to: "photo.jpg", in: mac)
        _ = await sandbox.engine(for: mac).sync()

        let report = await sandbox.engine(for: mac).resolveConflicts(choices: ["photo.jpg": .keepRemote])

        XCTAssertNotNil(report.summary, report.debugText)
        XCTAssertEqual(sandbox.read("photo.jpg", in: mac), "remote")
        XCTAssertEqual(report.info?.ahead, 0)
        XCTAssertEqual(report.info?.behind, 0)
    }

    func testResolveWithMissingChoiceReturnsConflictsAgain() async throws {
        try await sandbox.createRemote(seedFiles: ["x.txt": "1", "y.txt": "1"])
        let mac = try await sandbox.clone("mac")
        let other = try await sandbox.clone("other")
        try await sandbox.commitAndPush(["x.txt": "r", "y.txt": "r"], in: other)
        try sandbox.write("l", to: "x.txt", in: mac)
        try sandbox.write("l", to: "y.txt", in: mac)
        _ = await sandbox.engine(for: mac).sync()

        let report = await sandbox.engine(for: mac).resolveConflicts(choices: ["x.txt": .keepLocal])

        XCTAssertEqual(Set(report.conflicts?.map(\.path) ?? []), ["x.txt", "y.txt"], report.debugText)
        XCTAssertNil(report.info?.inProgressOperation)
        XCTAssertEqual(sandbox.read("y.txt", in: mac), "l")
    }

    // MARK: Safety checks

    func testUnfinishedMergeIsNotTouched() async throws {
        try await sandbox.createRemote(seedFiles: ["f.txt": "1"])
        let mac = try await sandbox.clone("mac")
        let other = try await sandbox.clone("other")
        try await sandbox.commitAndPush(["f.txt": "remote"], in: other)
        try sandbox.write("local", to: "f.txt", in: mac)
        try await sandbox.run(["commit", "-am", "local"], in: mac)
        try await sandbox.run(["fetch"], in: mac)
        _ = try? await sandbox.run(["merge", "origin/main"], in: mac)   // leaves conflict markers

        let report = await sandbox.engine(for: mac).sync()

        XCTAssertEqual(report.failure?.kind, .operationInProgress, report.debugText)
        XCTAssertEqual(report.status, .conflict)
        XCTAssertEqual(report.info?.inProgressOperation, .merge, "engine must not abort the user's merge")
    }

    func testIndexLockBlocksSync() async throws {
        try await sandbox.createRemote()
        let mac = try await sandbox.clone("mac")
        FileManager.default.createFile(atPath: mac.appendingPathComponent(".git/index.lock").path, contents: Data())
        let report = await sandbox.engine(for: mac).sync()
        XCTAssertEqual(report.failure?.kind, .indexLocked, report.debugText)
    }

    func testMissingFolderFails() async throws {
        let missing = sandbox.root.appendingPathComponent("does-not-exist")
        let report = await sandbox.engine(for: missing).sync()
        XCTAssertEqual(report.failure?.kind, .folderMissing)
    }

    func testNonRepositoryFails() async throws {
        let plain = sandbox.root.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let report = await sandbox.engine(for: plain).sync()
        XCTAssertEqual(report.failure?.kind, .notARepository, report.debugText)
    }

    func testRepositoryWithoutOriginFails() async throws {
        let repo = sandbox.root.appendingPathComponent("local-only")
        try await sandbox.run(["init", "-b", "main", repo.path], in: sandbox.root)
        let report = await sandbox.engine(for: repo).sync()
        XCTAssertEqual(report.failure?.kind, .noRemote, report.debugText)
    }

    func testIgnoredFilesAreNotCommitted() async throws {
        try await sandbox.createRemote()
        let mac = try await sandbox.clone("mac")
        try sandbox.write("x", to: ".DS_Store", in: mac)
        try sandbox.write("lock", to: "~$报告.docx", in: mac)
        try sandbox.write("real", to: "报告.docx", in: mac)

        let report = await sandbox.engine(for: mac).sync()

        XCTAssertEqual(report.summary?.committedFiles, 1, report.debugText)
        let files = try await sandbox.remoteFiles()
        XCTAssertTrue(files.contains("报告.docx"))
        XCTAssertFalse(files.contains(".DS_Store"))
        XCTAssertFalse(files.contains("~$报告.docx"))
    }

    func testOversizedFilesAreSkippedWithWarning() async throws {
        try await sandbox.createRemote()
        let mac = try await sandbox.clone("mac")
        var options = SyncOptions()
        options.largeFileLimitBytes = 1024
        options.largeFileWarningBytes = 512
        try sandbox.writeData(Data(repeating: 7, count: 4096), to: "big file.bin", in: mac)
        try sandbox.write("small", to: "small.txt", in: mac)

        let report = await sandbox.engine(for: mac, options: options).sync()

        XCTAssertEqual(report.summary?.committedFiles, 1, report.debugText)
        let files = try await sandbox.remoteFiles()
        XCTAssertTrue(files.contains("small.txt"))
        XCTAssertFalse(files.contains("big file.bin"))
        XCTAssertTrue(sandbox.exists("big file.bin", in: mac), "skipped file must stay on disk")
        XCTAssertTrue(report.warnings.contains { $0.contains("big file.bin") })
    }

    func testNetworkFailureIsClassifiedAndChangesStayLocal() async throws {
        try await sandbox.createRemote()
        let mac = try await sandbox.clone("mac")
        try await sandbox.run(["remote", "set-url", "origin", "https://gitcloud-sync-test.invalid/user/repo.git"], in: mac)
        try sandbox.write("offline edit", to: "offline.txt", in: mac)

        let report = await sandbox.engine(for: mac).sync()

        XCTAssertEqual(report.failure?.kind, .network, report.debugText)
        XCTAssertEqual(report.failure?.stage, .fetch)
        XCTAssertEqual(report.status, .networkUnavailable)
        XCTAssertEqual(sandbox.read("offline.txt", in: mac), "offline edit")
    }

    func testAuthFailureDoesNotHang() async throws {
        // A local HTTP server is not available in unit tests, so use a remote helper that
        // reports an auth error the way git does, and make sure the engine returns promptly.
        try await sandbox.createRemote()
        let mac = try await sandbox.clone("mac")
        let helper = sandbox.root.appendingPathComponent("git-remote-fakeauth")
        try """
        #!/bin/sh
        echo "fatal: Authentication failed for 'https://github.com/user/private.git/'" >&2
        exit 128
        """.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        try await sandbox.run(["remote", "set-url", "origin", "fakeauth::whatever"], in: mac)

        var env = sandbox.git.environment
        env["PATH"] = sandbox.root.path + ":" + (env["PATH"] ?? "")
        let git = GitEnvironment(gitURL: sandbox.git.gitURL, version: sandbox.git.version, environment: env)
        let engine = SyncEngine(client: GitClient(repositoryURL: mac, git: git))

        let start = Date()
        let report = await engine.sync()

        XCTAssertLessThan(Date().timeIntervalSince(start), 30)
        XCTAssertEqual(report.failure?.kind, .authentication, report.debugText)
        XCTAssertEqual(report.status, .needsAuth)
    }

    func testPushRaceIsRetried() async throws {
        // Remote moves between our fetch and push: simulated by a pre-push hook that pushes
        // from the other clone once.
        try await sandbox.createRemote(seedFiles: ["a.txt": "1"])
        let mac = try await sandbox.clone("mac")
        let other = try await sandbox.clone("other")
        try sandbox.write("other\n", to: "b.txt", in: other)
        try await sandbox.run(["add", "-A"], in: other)
        try await sandbox.run(["commit", "-m", "racing"], in: other)
        let marker = sandbox.root.appendingPathComponent("raced")
        let hook = mac.appendingPathComponent(".git/hooks/pre-push")
        try """
        #!/bin/sh
        if [ ! -f "\(marker.path)" ]; then
          touch "\(marker.path)"
          cd "\(other.path)" && env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git push -q origin main
        fi
        exit 0
        """.write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        try sandbox.write("mine\n", to: "c.txt", in: mac)

        let report = await sandbox.engine(for: mac).sync()

        XCTAssertNotNil(report.summary, report.debugText)
        let files = try await sandbox.remoteFiles()
        XCTAssertTrue(files.contains("b.txt"))
        XCTAssertTrue(files.contains("c.txt"))
    }

    func testExportRemoteVersionDoesNotModifyRepository() async throws {
        try await sandbox.createRemote(seedFiles: ["doc.txt": "1"])
        let mac = try await sandbox.clone("mac")
        let other = try await sandbox.clone("other")
        try await sandbox.commitAndPush(["doc.txt": "remote"], in: other)
        try sandbox.write("local", to: "doc.txt", in: mac)
        _ = await sandbox.engine(for: mac).sync()

        let url = try await sandbox.engine(for: mac).exportRemoteVersion(of: "doc.txt")

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "remote")
        XCTAssertEqual(sandbox.read("doc.txt", in: mac), "local")
    }
}
