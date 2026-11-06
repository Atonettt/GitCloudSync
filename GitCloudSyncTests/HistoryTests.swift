import Foundation
import XCTest

final class HistoryTests: XCTestCase {
    private var sandbox: GitSandbox!

    override func setUp() async throws {
        sandbox = try GitSandbox(git: try await GitSandbox.makeGit())
    }

    override func tearDown() async throws {
        sandbox = nil
    }

    private func options(_ machine: String) -> SyncOptions {
        var options = SyncOptions()
        options.machineName = machine
        return options
    }

    private func browser(_ repo: URL) -> HistoryBrowser {
        HistoryBrowser(client: GitClient(repositoryURL: repo, git: sandbox.git))
    }

    /// Writes each content in turn and syncs after every write, like edits between scheduled syncs.
    private func syncVersions(_ contents: [String], of path: String, in repo: URL, machine: String = "Mac-A") async throws {
        for content in contents {
            try sandbox.write(content, to: path, in: repo)
            let report = await sandbox.engine(for: repo, options: options(machine)).sync()
            XCTAssertNotNil(report.summary, report.debugText)
        }
    }

    // MARK: Browsing

    func testFileVersionsAreListedNewestFirst() async throws {
        try await sandbox.createRemote()
        let mac = try await sandbox.clone("mac")
        try await syncVersions(["v1", "v2 longer", "v3"], of: "文档/合同.txt", in: mac)

        let versions = try await browser(mac).versions(of: "文档/合同.txt")

        XCTAssertEqual(versions.count, 3)
        XCTAssertEqual(versions.map(\.size), [2, 9, 2])
        XCTAssertTrue(versions.allSatisfy { $0.commit.kind == .autoSync && $0.commit.machine == "Mac-A" })
        let oldest = try await browser(mac).content(of: versions[2].path, at: versions[2].commit.id)
        XCTAssertEqual(String(decoding: oldest, as: UTF8.self), "v1")
    }

    func testPreviousVersionOfAFile() async throws {
        try await sandbox.createRemote()
        let mac = try await sandbox.clone("mac")
        try await syncVersions(["v1", "v2"], of: "a.txt", in: mac)
        try await syncVersions(["other"], of: "b.txt", in: mac)
        try await syncVersions(["v3"], of: "a.txt", in: mac)

        let versions = try await browser(mac).versions(of: "a.txt")
        let newest = versions[0].commit.id
        let previous = try await browser(mac).previousVersion(of: "a.txt", before: newest)
        XCTAssertEqual(previous?.commit, versions[1].commit.id, "skips commits that didn't touch the file")
        let content = try await browser(mac).content(of: "a.txt", at: try XCTUnwrap(previous?.commit))
        XCTAssertEqual(String(decoding: content, as: UTF8.self), "v2")

        let first = try await browser(mac).previousVersion(of: "a.txt", before: versions[2].commit.id)
        XCTAssertNil(first, "the first version has nothing before it")
    }

    func testLastSyncChanges() async throws {
        try await sandbox.createRemote(seedFiles: ["a.txt": "a", "gone.txt": "x"])
        let mac = try await sandbox.clone("mac")
        try sandbox.write("a2", to: "a.txt", in: mac)
        try sandbox.write("new", to: "docs/b.txt", in: mac)
        try FileManager.default.removeItem(at: mac.appendingPathComponent("gone.txt"))
        let report = await sandbox.engine(for: mac, options: options("Mac-A")).sync()
        XCTAssertNotNil(report.summary, report.debugText)

        let last = await browser(mac).lastSyncChanges()
        XCTAssertNotNil(last.date)
        XCTAssertEqual(last.changes, ["a.txt": "M", "docs/b.txt": "A"])
    }

    func testPreviousSyncPoint() async throws {
        try await sandbox.createRemote()
        let mac = try await sandbox.clone("mac")
        try await syncVersions(["v1"], of: "a.txt", in: mac)
        try await syncVersions(["other"], of: "b.txt", in: mac)

        let head = try await sandbox.run(["rev-parse", "HEAD"], in: mac).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let point = try await browser(mac).previousSyncPoint(before: head, path: "a.txt")
        XCTAssertEqual(point?.hasFile, true)
        let content = try await browser(mac).content(of: "a.txt", at: try XCTUnwrap(point?.commit))
        XCTAssertEqual(String(decoding: content, as: UTF8.self), "v1", "a.txt didn't change at the last sync")
        let newFile = try await browser(mac).previousSyncPoint(before: head, path: "b.txt")
        XCTAssertEqual(newFile?.hasFile, false, "b.txt was added in the last sync")
    }

    func testFilesOfAnOlderVersion() async throws {
        try await sandbox.createRemote()
        let mac = try await sandbox.clone("mac")
        try await syncVersions(["v1"], of: "a.txt", in: mac)
        let first = try await browser(mac).timeline().first!.id
        try FileManager.default.removeItem(at: mac.appendingPathComponent("a.txt"))
        try await syncVersions(["b"], of: "资料/b.txt", in: mac)

        let then = try await browser(mac).trackedFiles(at: first)
        let now = try await browser(mac).trackedFiles()

        XCTAssertEqual(Set(then), ["a.txt", "README.md"])
        XCTAssertEqual(Set(now), ["README.md", "资料/b.txt"])
    }

    func testCommitMessagesAreParsed() {
        let auto = HistoryCommit(id: "a", parents: [], date: Date(), author: "x", subject: "GitSync：我的 MacBook 自动同步 2026/11/03 15:30")
        XCTAssertEqual(auto.kind, .autoSync)
        XCTAssertEqual(auto.machine, "我的 MacBook")
        let merge = HistoryCommit(id: "b", parents: [], date: Date(), author: "x", subject: "GitSync：合并来自 GitHub 的更新（iMac）")
        XCTAssertEqual(merge.kind, .merge)
        XCTAssertEqual(merge.source, "iMac")
        let restore = HistoryCommit(id: "c", parents: [], date: Date(), author: "x", subject: "GitSync：iMac 恢复「a.docx」到 2026年11月1日 15:30 的版本")
        XCTAssertEqual(restore.kind, .restore)
        XCTAssertEqual(restore.machine, "iMac")
        XCTAssertEqual(restore.title, "恢复「a.docx」到 2026年11月1日 15:30 的版本")
        let englishAuto = HistoryCommit(id: "e", parents: [], date: Date(), author: "x", subject: "GitSync: Anchor's MacBook auto-sync 11/03/2026, 15:30")
        XCTAssertEqual(englishAuto.kind, .autoSync)
        XCTAssertEqual(englishAuto.machine, "Anchor's MacBook")
        let englishMerge = HistoryCommit(id: "f", parents: [], date: Date(), author: "x", subject: "GitSync: merged updates from GitHub (iMac)")
        XCTAssertEqual(englishMerge.kind, .merge)
        XCTAssertEqual(englishMerge.machine, "iMac")
        let englishRestore = HistoryCommit(id: "g", parents: [], date: Date(), author: "x", subject: "GitSync: iMac restored “a.docx” to the version of Nov 1, 2026 at 15:30")
        XCTAssertEqual(englishRestore.kind, .restore)
        XCTAssertEqual(englishRestore.machine, "iMac")
        XCTAssertEqual(englishRestore.title, "restored “a.docx” to the version of Nov 1, 2026 at 15:30")
        let manual = HistoryCommit(id: "d", parents: [], date: Date(), author: "Tester", subject: "Update README")
        XCTAssertEqual(manual.kind, .other)
        XCTAssertEqual(manual.source, "Tester")
    }

    func testTimelineShowsMergedRemoteChanges() async throws {
        try await sandbox.createRemote()
        let mac = try await sandbox.clone("mac")
        let other = try await sandbox.clone("other")
        try await sandbox.commitAndPush(["remote.txt": "from other"], in: other)
        try sandbox.write("local", to: "local.txt", in: mac)
        let report = await sandbox.engine(for: mac, options: options("Mac-A")).sync()
        XCTAssertNotNil(report.summary, report.debugText)

        let timeline = try await browser(mac).timeline()

        XCTAssertEqual(timeline.first?.kind, .merge)
        XCTAssertEqual(timeline.first?.changes.map(\.path), ["remote.txt"], "a merge lists what came from GitHub")
        XCTAssertEqual(timeline.dropFirst().first?.changes.map(\.path), ["local.txt"])
        XCTAssertEqual(timeline.last?.subject, "initial")
    }

    // MARK: Restoring one file

    func testRestoreFileCreatesNewCommitAndReachesOtherMac() async throws {
        try await sandbox.createRemote()
        let mac = try await sandbox.clone("mac")
        let other = try await sandbox.clone("other")
        try await syncVersions(["v1", "v2", "v3"], of: "notes.txt", in: mac)
        let before = try await browser(mac).versions(of: "notes.txt")

        let report = await sandbox.engine(for: mac, options: options("Mac-A"))
            .restore(.file(path: "notes.txt", sourcePath: "notes.txt", commit: before[2].commit.id), description: "「notes.txt」到 v1")

        XCTAssertEqual(report.summary?.restoredFiles, 1, report.debugText)
        XCTAssertEqual(report.summary?.uploadedCommits, 1)
        XCTAssertEqual(sandbox.read("notes.txt", in: mac), "v1")
        let remote = try await sandbox.remoteContent("notes.txt")
        XCTAssertEqual(remote, "v1")
        let after = try await browser(mac).versions(of: "notes.txt")
        XCTAssertEqual(after.count, 4, "the restore is a new version; nothing was rewritten")
        XCTAssertEqual(after.first?.commit.kind, .restore)
        XCTAssertTrue(report.warnings.contains { $0.contains("refs/gitcloud-sync/backup/") })

        let otherReport = await sandbox.engine(for: other).sync()
        XCTAssertNotNil(otherReport.summary, otherReport.debugText)
        XCTAssertEqual(sandbox.read("notes.txt", in: other), "v1")

        // A restore can itself be undone.
        let undo = await sandbox.engine(for: mac, options: options("Mac-A"))
            .restore(.file(path: "notes.txt", sourcePath: "notes.txt", commit: after[1].commit.id), description: "撤销")
        XCTAssertEqual(undo.summary?.restoredFiles, 1, undo.debugText)
        XCTAssertEqual(sandbox.read("notes.txt", in: mac), "v3")
    }

    func testRestoreSavesUnsyncedEditsFirst() async throws {
        try await sandbox.createRemote()
        let mac = try await sandbox.clone("mac")
        try await syncVersions(["v1", "v2"], of: "notes.txt", in: mac)
        let versions = try await browser(mac).versions(of: "notes.txt")
        try sandbox.write("unsynced edit", to: "notes.txt", in: mac)

        let report = await sandbox.engine(for: mac).restore(
            .file(path: "notes.txt", sourcePath: "notes.txt", commit: versions[1].commit.id), description: "到 v1")

        XCTAssertEqual(report.summary?.committedFiles, 1, report.debugText)
        XCTAssertEqual(sandbox.read("notes.txt", in: mac), "v1")
        let history = try await browser(mac).versions(of: "notes.txt")
        let contents = try await history.asyncMap { try await self.browser(mac).content(of: $0.path, at: $0.commit.id) }
        XCTAssertTrue(contents.contains(Data("unsynced edit".utf8)), "the unsynced edit is kept in history")
    }

    func testRestoreFollowsRenames() async throws {
        try await sandbox.createRemote()
        let mac = try await sandbox.clone("mac")
        try await syncVersions(["original text that is long enough to be detected as a rename\n"], of: "old name.txt", in: mac)
        try FileManager.default.moveItem(at: mac.appendingPathComponent("old name.txt"), to: mac.appendingPathComponent("new name.txt"))
        _ = await sandbox.engine(for: mac).sync()
        try await syncVersions(["rewritten"], of: "new name.txt", in: mac)

        let versions = try await browser(mac).versions(of: "new name.txt")
        let original = try XCTUnwrap(versions.last)
        XCTAssertEqual(original.path, "old name.txt")

        let report = await sandbox.engine(for: mac).restore(
            .file(path: "new name.txt", sourcePath: original.path, commit: original.commit.id), description: "改名前")

        XCTAssertNotNil(report.summary, report.debugText)
        XCTAssertEqual(sandbox.read("new name.txt", in: mac), "original text that is long enough to be detected as a rename\n")
        XCTAssertFalse(sandbox.exists("old name.txt", in: mac))
    }

    func testRestoreWhenRemoteMovedMergesFirst() async throws {
        try await sandbox.createRemote()
        let mac = try await sandbox.clone("mac")
        let other = try await sandbox.clone("other")
        try await syncVersions(["v1", "v2"], of: "notes.txt", in: mac)
        let versions = try await browser(mac).versions(of: "notes.txt")
        try await sandbox.commitAndPush(["other.txt": "new on other mac"], in: other)

        let report = await sandbox.engine(for: mac).restore(
            .file(path: "notes.txt", sourcePath: "notes.txt", commit: versions[1].commit.id), description: "到 v1")

        XCTAssertEqual(report.summary?.downloadedCommits, 1, report.debugText)
        XCTAssertEqual(sandbox.read("other.txt", in: mac), "new on other mac")
        let remote = try await sandbox.remoteContent("notes.txt")
        XCTAssertEqual(remote, "v1")
    }

    func testRestoreOfflineKeepsResultLocally() async throws {
        try await sandbox.createRemote()
        let mac = try await sandbox.clone("mac")
        try await syncVersions(["v1", "v2"], of: "notes.txt", in: mac)
        let versions = try await browser(mac).versions(of: "notes.txt")
        try await sandbox.run(["remote", "set-url", "origin", "https://gitcloud-sync-test.invalid/user/repo.git"], in: mac)

        let report = await sandbox.engine(for: mac).restore(
            .file(path: "notes.txt", sourcePath: "notes.txt", commit: versions[1].commit.id), description: "到 v1")

        XCTAssertEqual(report.failure?.mappedStatus, .networkUnavailable, report.debugText)
        XCTAssertEqual(report.failure?.message, "已在本地恢复，但无法连接 GitHub")
        XCTAssertEqual(sandbox.read("notes.txt", in: mac), "v1")
        XCTAssertEqual(report.info?.changedFiles, 0, "the restore is committed locally")
        XCTAssertEqual(report.info?.ahead, 1)
    }

    func testRestoreIsRefusedDuringUnfinishedMerge() async throws {
        try await sandbox.createRemote()
        let mac = try await sandbox.clone("mac")
        try await syncVersions(["v1", "v2"], of: "notes.txt", in: mac)
        let versions = try await browser(mac).versions(of: "notes.txt")
        try "".write(to: mac.appendingPathComponent(".git/MERGE_HEAD"), atomically: true, encoding: .utf8)

        let report = await sandbox.engine(for: mac).restore(
            .file(path: "notes.txt", sourcePath: "notes.txt", commit: versions[1].commit.id), description: "到 v1")

        XCTAssertEqual(report.failure?.kind, .operationInProgress, report.debugText)
        XCTAssertEqual(sandbox.read("notes.txt", in: mac), "v2")
    }

    // MARK: Deleted files

    func testDeletedFileIsListedAndRestored() async throws {
        try await sandbox.createRemote()
        let mac = try await sandbox.clone("mac")
        try await syncVersions(["keep me"], of: "报告/草稿.txt", in: mac)
        try FileManager.default.removeItem(at: mac.appendingPathComponent("报告/草稿.txt"))
        _ = await sandbox.engine(for: mac, options: options("Mac-A")).sync()

        let deleted = try await browser(mac).deletedFiles()
        let file = try XCTUnwrap(deleted.first)
        XCTAssertEqual(deleted.map(\.path), ["报告/草稿.txt"])
        XCTAssertEqual(file.deletedIn.machine, "Mac-A")
        XCTAssertEqual(file.size, 7)

        let report = await sandbox.engine(for: mac).restore(
            .file(path: file.path, sourcePath: file.path, commit: file.lastVersionCommit), description: "已删除的文件")

        XCTAssertEqual(report.summary?.restoredFiles, 1, report.debugText)
        XCTAssertEqual(sandbox.read("报告/草稿.txt", in: mac), "keep me")
        let remoteFiles = try await sandbox.remoteFiles()
        XCTAssertTrue(remoteFiles.contains("报告/草稿.txt"))
        let remaining = try await browser(mac).deletedFiles()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testSaveCopyLeavesOriginalUntouched() async throws {
        try await sandbox.createRemote()
        let mac = try await sandbox.clone("mac")
        try await syncVersions(["v1", "v2"], of: "合同.docx", in: mac)
        let versions = try await browser(mac).versions(of: "合同.docx")

        let copy = try await browser(mac).saveCopy(path: "合同.docx", commit: versions[1].commit.id, date: versions[1].commit.date)

        XCTAssertTrue(copy.hasPrefix("合同 ("), copy)
        XCTAssertTrue(copy.hasSuffix(" 版本).docx"), copy)
        XCTAssertEqual(sandbox.read(copy, in: mac), "v1")
        XCTAssertEqual(sandbox.read("合同.docx", in: mac), "v2")
        let second = try await browser(mac).saveCopy(path: "合同.docx", commit: versions[1].commit.id, date: versions[1].commit.date)
        XCTAssertNotEqual(second, copy, "an existing copy is never overwritten")
    }

    // MARK: Whole repository

    func testRepositoryRestorePreviewAndApply() async throws {
        try await sandbox.createRemote()
        let mac = try await sandbox.clone("mac")
        try sandbox.write("a1", to: "a.txt", in: mac)
        try sandbox.write("b1", to: "b.txt", in: mac)
        _ = await sandbox.engine(for: mac).sync()
        let snapshot = try await browser(mac).timeline()
        let target = try XCTUnwrap(snapshot.first)
        try sandbox.write("a2", to: "a.txt", in: mac)
        try FileManager.default.removeItem(at: mac.appendingPathComponent("b.txt"))
        try sandbox.write("c", to: "c.txt", in: mac)
        _ = await sandbox.engine(for: mac).sync()
        try sandbox.write("untracked but ignored", to: ".DS_Store", in: mac)

        let preview = try await browser(mac).previewRestore(to: target.id)
        XCTAssertEqual(preview.modified, ["a.txt"])
        XCTAssertEqual(preview.restored, ["b.txt"])
        XCTAssertEqual(preview.removed, ["c.txt"])

        let report = await sandbox.engine(for: mac).restore(.repository(commit: target.id), description: "整个仓库")

        XCTAssertEqual(report.summary?.restoredFiles, 3, report.debugText)
        XCTAssertEqual(sandbox.read("a.txt", in: mac), "a1")
        XCTAssertEqual(sandbox.read("b.txt", in: mac), "b1")
        XCTAssertFalse(sandbox.exists("c.txt", in: mac))
        XCTAssertTrue(sandbox.exists(".DS_Store", in: mac), "files outside version control are left alone")
        let remoteFiles = try await sandbox.remoteFiles()
        XCTAssertEqual(Set(remoteFiles), ["README.md", "a.txt", "b.txt"])
        let deleted = try await browser(mac).deletedFiles()
        XCTAssertEqual(deleted.map(\.path), ["c.txt"], "the removed file stays recoverable")
    }

    func testRepositoryRestoreSkipsFilesIgnoredToday() async throws {
        try await sandbox.createRemote()
        let mac = try await sandbox.clone("mac")
        let other = try await sandbox.clone("other")
        // An old version that tracked a .DS_Store, committed by a tool without GitSync's ignore rules.
        try await sandbox.commitAndPush([".DS_Store": "finder junk", "doc.txt": "d1"], in: other)
        try FileManager.default.removeItem(at: other.appendingPathComponent(".DS_Store"))
        try await sandbox.commitAndPush(["doc.txt": "d2"], in: other)
        _ = await sandbox.engine(for: mac).sync()
        let timeline = try await browser(mac).timeline()
        let target = try XCTUnwrap(timeline.first { $0.changes.contains { $0.path == ".DS_Store" && $0.status == "A" } })

        let report = await sandbox.engine(for: mac).restore(.repository(commit: target.id), description: "整个仓库")

        XCTAssertEqual(report.summary?.restoredFiles, 1, report.debugText)
        XCTAssertEqual(sandbox.read("doc.txt", in: mac), "d1")
        XCTAssertFalse(sandbox.exists(".DS_Store", in: mac))
        XCTAssertTrue(report.warnings.contains { $0.contains(".DS_Store") })
        let remoteFiles = try await sandbox.remoteFiles()
        XCTAssertFalse(remoteFiles.contains(".DS_Store"))
    }

    func testRestoringToCurrentContentIsNoChange() async throws {
        try await sandbox.createRemote()
        let mac = try await sandbox.clone("mac")
        try await syncVersions(["v1"], of: "notes.txt", in: mac)
        let current = try await browser(mac).timeline()
        let head = try XCTUnwrap(current.first)

        let report = await sandbox.engine(for: mac).restore(.repository(commit: head.id), description: "当前")

        XCTAssertTrue(report.isNoChanges, report.debugText)
        XCTAssertTrue(report.warnings.contains { $0.contains("无需恢复") })
    }
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var result: [T] = []
        for element in self { result.append(try await transform(element)) }
        return result
    }
}
