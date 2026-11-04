import Foundation
import XCTest

final class RepositoryLocatorTests: XCTestCase {
    private var sandbox: GitSandbox!

    override func setUp() async throws {
        sandbox = try GitSandbox(git: try await GitSandbox.makeGit())
    }

    override func tearDown() async throws {
        sandbox = nil
    }

    private var locator: RepositoryLocator { RepositoryLocator(git: sandbox.git) }

    func testBookmarkFollowsMoveAndRename() async throws {
        try await sandbox.createRemote()
        let mac = try await sandbox.clone("mac")
        let bookmark = try XCTUnwrap(RepositoryLocator.bookmark(for: mac))
        XCTAssertEqual(RepositoryLocator.locate(path: mac.path, bookmark: bookmark), .unchanged)

        let moved = sandbox.root.appendingPathComponent("elsewhere/Renamed folder")
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: mac, to: moved)

        guard case .moved(let found) = RepositoryLocator.locate(path: mac.path, bookmark: bookmark) else {
            return XCTFail("the bookmark should find the moved folder")
        }
        XCTAssertEqual(RepositoryCreator.canonicalPath(found.path), RepositoryCreator.canonicalPath(moved.path))
    }

    func testMissingWithoutBookmarkOrTarget() throws {
        let gone = sandbox.root.appendingPathComponent("gone")
        XCTAssertEqual(RepositoryLocator.locate(path: gone.path, bookmark: nil), .missing)
    }

    func testTrashIsRecognised() {
        XCTAssertTrue(RepositoryLocator.isInTrash(URL(fileURLWithPath: "/Users/me/.Trash/Photo")))
        XCTAssertTrue(RepositoryLocator.isInTrash(URL(fileURLWithPath: "/Volumes/Disk/.Trashes/501/Photo")))
        XCTAssertFalse(RepositoryLocator.isInTrash(URL(fileURLWithPath: "/Users/me/Desktop/Photo")))
    }

    func testMatchesSameRepositoryOnly() async throws {
        try await sandbox.createRemote()
        let mac = try await sandbox.clone("mac")
        let expected = await locator.identity(of: mac)
        XCTAssertNotNil(expected.remote)
        XCTAssertNotNil(expected.commit)

        let copy = try await sandbox.clone("copy-elsewhere")
        let sameRepository = await locator.matches(copy, expected: expected)
        XCTAssertTrue(sameRepository, "a clone of the same GitHub repository is accepted")

        let other = sandbox.root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try await sandbox.run(["init", "-q", "-b", "main"], in: other)
        let unrelated = await locator.matches(other, expected: expected)
        XCTAssertFalse(unrelated, "an unrelated repository is refused")

        let subfolder = mac.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)
        let inside = await locator.matches(subfolder, expected: expected)
        XCTAssertFalse(inside, "a folder inside the repository is not its root")
    }

    func testMatchesByCommitWhenRemoteChanged() async throws {
        try await sandbox.createRemote()
        let mac = try await sandbox.clone("mac")
        let expected = await locator.identity(of: mac)
        try await sandbox.run(["remote", "set-url", "origin", "https://github.com/someone/renamed.git"], in: mac)
        let found = await locator.matches(mac, expected: expected)
        XCTAssertTrue(found, "a known commit identifies the repository even if its remote changed")
    }

    func testOldConfigurationDecodesWithoutBookmark() throws {
        let json = #"{"id":"7A1E0D0C-0000-4000-8000-000000000001","path":"/a","displayName":"A"}"#
        let repo = try JSONDecoder().decode(RepositoryConfig.self, from: Data(json.utf8))
        XCTAssertNil(repo.bookmark)
        XCTAssertNil(repo.knownRemote)
    }
}
