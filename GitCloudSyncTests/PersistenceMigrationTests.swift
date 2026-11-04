import Foundation
import XCTest

final class PersistenceMigrationTests: XCTestCase {
    private func decode(_ json: String) throws -> PersistedState {
        try JSONDecoder().decode(PersistedState.self, from: Data(json.utf8))
    }

    private let twoRepositories = """
    [{"id":"7A1E0D0C-0000-4000-8000-000000000001","path":"/a","displayName":"A","autoSyncEnabled":true},
     {"id":"7A1E0D0C-0000-4000-8000-000000000002","path":"/b","displayName":"B","autoSyncEnabled":false}]
    """

    func testPausedGlobalSwitchTurnsEveryRepositoryOff() throws {
        var state = try decode(#"{"version":1,"settings":{"autoSyncEnabled":false},"repositories":\#(twoRepositories)}"#)

        XCTAssertTrue(state.migrate())

        XCTAssertEqual(state.version, PersistedState.currentVersion)
        XCTAssertEqual(state.repositories.map(\.autoSyncEnabled), [false, false],
                       "nothing synced automatically before, so nothing starts after the upgrade")
    }

    func testRunningGlobalSwitchKeepsEachRepositorysChoice() throws {
        var state = try decode(#"{"settings":{"autoSyncEnabled":true},"repositories":\#(twoRepositories)}"#)

        XCTAssertTrue(state.migrate())

        XCTAssertEqual(state.repositories.map(\.autoSyncEnabled), [true, false])
    }

    func testCurrentStateIsNotMigratedAgain() throws {
        var state = PersistedState(settings: AppSettings(), repositories: [RepositoryConfig(path: "/a", displayName: "A")])
        XCTAssertEqual(state.version, PersistedState.currentVersion)

        XCTAssertFalse(state.migrate())
        XCTAssertEqual(state.repositories.first?.autoSyncEnabled, true, "the old global value no longer matters")
    }
}
