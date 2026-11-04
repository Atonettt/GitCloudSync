import Foundation
import XCTest

final class RepositoryUsageTests: XCTestCase {
    private var sandbox: GitSandbox!

    override func setUp() async throws {
        sandbox = try GitSandbox(git: try await GitSandbox.makeGit())
    }

    override func tearDown() async throws {
        sandbox = nil
    }

    private func scanner(_ repo: URL) -> RepositoryUsageScanner {
        RepositoryUsageScanner(client: GitClient(repositoryURL: repo, git: sandbox.git))
    }

    /// Random bytes do not compress, so stored sizes are predictable.
    private func randomData(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: 0...255) })
    }

    private func commitAll(_ repo: URL, _ message: String) async throws {
        try await sandbox.run(["add", "-A"], in: repo)
        try await sandbox.run(["commit", "-qm", message], in: repo)
    }

    func testMeasureSeparatesFilesFromHistory() async throws {
        try await sandbox.createRemote()
        let mac = try await sandbox.clone("mac")
        let before = try await scanner(mac).measure()

        try sandbox.writeData(randomData(300_000), to: "资料/scan.pdf", in: mac)
        let uncommitted = try await scanner(mac).measure()
        XCTAssertGreaterThanOrEqual(uncommitted.fileBytes - before.fileBytes, 300_000)
        XCTAssertLessThan(uncommitted.historyBytes - before.historyBytes, 100_000, "nothing is in history before a commit")

        try await commitAll(mac, "add pdf")
        let committed = try await scanner(mac).measure()
        XCTAssertGreaterThanOrEqual(committed.historyBytes - before.historyBytes, 290_000)
        XCTAssertEqual(committed.level, .normal)
    }

    func testLargestFilesAddsUpAllVersionsIncludingDeletedFiles() async throws {
        try await sandbox.createRemote()
        let mac = try await sandbox.clone("mac")
        for round in 1...3 {
            try sandbox.writeData(randomData(100_000 * round), to: "演示.pptx", in: mac)
            try await commitAll(mac, "edit \(round)")
        }
        try sandbox.writeData(randomData(250_000), to: "old/video.mov", in: mac)
        try await commitAll(mac, "add video")
        try FileManager.default.removeItem(at: mac.appendingPathComponent("old/video.mov"))
        try await commitAll(mac, "delete video")

        let files = try await scanner(mac).largestFiles()

        XCTAssertEqual(files.first?.path, "演示.pptx")
        XCTAssertEqual(files.first?.versions, 3)
        XCTAssertEqual(files.first?.largestVersionBytes, 300_000)
        XCTAssertGreaterThanOrEqual(files.first?.storedBytes ?? 0, 590_000, "every version is stored")
        let video = try XCTUnwrap(files.first { $0.path == "old/video.mov" })
        XCTAssertEqual(video.versions, 1, "a deleted file still takes space in history")
        XCTAssertEqual(files.last?.path, "README.md")
    }

    func testLevels() {
        XCTAssertEqual(RepositoryUsage(fileBytes: 0, historyBytes: 900 << 20).level, .normal)
        XCTAssertEqual(RepositoryUsage(fileBytes: 0, historyBytes: 1 << 30).level, .large)
        XCTAssertEqual(RepositoryUsage(fileBytes: 0, historyBytes: 6 << 30).level, .veryLarge)
    }
}
