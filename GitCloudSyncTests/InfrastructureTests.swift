import Foundation
import XCTest

final class ProcessRunnerTests: XCTestCase {
    func testTimeoutTerminatesProcess() async throws {
        let start = Date()
        let result = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], timeout: 0.5
        )
        XCTAssertTrue(result.timedOut)
        XCTAssertFalse(result.succeeded)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }

    func testStdinIsNullSoReadsDoNotBlock() async throws {
        let result = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], timeout: 5
        )
        XCTAssertTrue(result.succeeded)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.stdout, "")
    }

    func testCapturesLargeOutputAndStderr() async throws {
        let result = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "yes x | head -c 2000000; echo oops >&2; exit 3"],
            timeout: 20
        )
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertEqual(result.stdoutData.count, 2_000_000)
        XCTAssertEqual(result.stderr, "oops\n")
    }
}

final class GitEnvironmentTests: XCTestCase {
    func testEnvironmentDisablesPromptsAndFixesPath() {
        let env = GitEnvironment.buildEnvironment(base: [
            "PATH": "/usr/bin:/bin",
            "GIT_ASKPASS": "/some/askpass",
            "DYLD_INSERT_LIBRARIES": "x",
        ])
        XCTAssertEqual(env["GIT_TERMINAL_PROMPT"], "0")
        XCTAssertEqual(env["GCM_INTERACTIVE"], "never")
        XCTAssertNil(env["GIT_ASKPASS"])
        XCTAssertNil(env["DYLD_INSERT_LIBRARIES"])
        XCTAssertTrue(env["PATH"]!.hasPrefix("/opt/homebrew/bin:"))
        XCTAssertNotNil(env["GIT_SSH_COMMAND"]?.range(of: "BatchMode=yes"))
    }

    func testDetectFindsGit() async throws {
        let env = try await GitSandbox.makeGit()
        XCTAssertTrue(env.version.hasPrefix("git version"))
    }

    func testCredentialIsPassedViaEnvironmentNotArguments() async throws {
        let git = try await GitSandbox.makeGit()
        let client = GitClient(repositoryURL: FileManager.default.temporaryDirectory, git: git,
                               credential: GitCredential(token: "secret-token-123"))
        XCTAssertFalse(client.configArguments.joined().contains("secret-token-123"))
        XCTAssertEqual(client.environment["GITCLOUD_SYNC_TOKEN"], "secret-token-123")

        // The inline helper must hand the token to git.
        let input = Data("protocol=https\nhost=github.com\n\n".utf8)
        let result = try await client.run(["credential", "fill"], timeout: 15, stdin: input)
        XCTAssertTrue(result.succeeded, result.stderr)
        XCTAssertTrue(result.stdout.contains("username=x-access-token"))
        XCTAssertTrue(result.stdout.contains("password=secret-token-123"))
    }
}

final class ClassifierTests: XCTestCase {
    func testClassification() {
        let cases: [(String, FailureKind)] = [
            ("fatal: could not read Username for 'https://github.com': terminal prompts disabled", .authentication),
            ("remote: Invalid username or token.\nfatal: Authentication failed for 'https://github.com/a/b.git/'", .authentication),
            ("remote: Repository not found.\nfatal: repository 'https://github.com/a/b.git/' not found", .repositoryNotFound),
            ("fatal: unable to access 'https://github.com/a/b.git/': Could not resolve host: github.com", .network),
            ("fatal: unable to access 'https://github.com/a/b.git/': The requested URL returned error: 503", .serverUnavailable),
            ("fatal: unable to access 'https://github.com/a/b.git/': The requested URL returned error: 403", .authentication),
            ("remote: error: GH001: Large files detected.", .largeFile),
            ("fatal: Unable to create '/x/.git/index.lock': File exists.", .indexLocked),
            ("fatal: refusing to merge unrelated histories", .unrelatedHistories),
            (" ! [rejected]        main -> main (fetch first)", .pushRejected),
            ("git@github.com: Permission denied (publickey).", .authentication),
            ("something odd", .unknown),
        ]
        for (text, expected) in cases {
            XCTAssertEqual(GitErrorClassifier.classify(output: text, timedOut: false), expected, text)
        }
        XCTAssertEqual(GitErrorClassifier.classify(output: "", timedOut: true), .timeout)
    }

    func testStatusMapping() {
        XCTAssertEqual(SyncFailure(kind: .authentication, stage: .fetch).mappedStatus, .needsAuth)
        XCTAssertEqual(SyncFailure(kind: .network, stage: .fetch).mappedStatus, .networkUnavailable)
        XCTAssertEqual(SyncFailure(kind: .operationInProgress, stage: .preflight).mappedStatus, .conflict)
        XCTAssertEqual(SyncFailure(kind: .serverUnavailable, stage: .push).mappedStatus, .failed)
    }

    func testWebURL() {
        XCTAssertEqual(RepositoryInfo.webURL(fromRemote: "git@github.com:owner/repo.git")?.absoluteString, "https://github.com/owner/repo")
        XCTAssertEqual(RepositoryInfo.webURL(fromRemote: "https://user@github.com/owner/repo.git")?.absoluteString, "https://github.com/owner/repo")
    }
}

final class CoordinatorTests: XCTestCase {
    func testDuplicateRunForSameRepositoryIsRejected() async {
        let coordinator = SyncCoordinator(maxConcurrent: 2)
        let id = UUID()
        async let first: Int? = coordinator.run(id: id) {
            try? await Task.sleep(for: .milliseconds(400))
            return 1
        }
        try? await Task.sleep(for: .milliseconds(100))
        let second = await coordinator.run(id: id) { 2 }
        let firstValue = await first
        XCTAssertEqual(firstValue, 1)
        XCTAssertNil(second, "a second request for the same repository must be rejected")
        let afterwards = await coordinator.run(id: id) { 3 }
        XCTAssertEqual(afterwards, 3)
    }

    func testConcurrencyIsCapped() async {
        let coordinator = SyncCoordinator(maxConcurrent: 2)
        let counter = Counter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    _ = await coordinator.run(id: UUID()) {
                        await counter.enter()
                        try? await Task.sleep(for: .milliseconds(100))
                        await counter.leave()
                    }
                }
            }
        }
        let peak = await counter.peak
        XCTAssertEqual(peak, 2)
    }

    actor Counter {
        var current = 0
        var peak = 0
        func enter() { current += 1; peak = max(peak, current) }
        func leave() { current -= 1 }
    }
}

final class PersistenceTests: XCTestCase {
    func testStateRoundTripRestoresConfiguration() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("state-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = JSONFileStore<PersistedState>(url: url)

        var settings = AppSettings()
        settings.autoSyncEnabled = true
        settings.intervalMinutes = 17
        var repo = RepositoryConfig(path: "/Users/me/Desktop/MacGit", displayName: "MacGit")
        repo.autoSyncEnabled = false
        repo.lastStatus = .conflict
        repo.conflictFiles = [ConflictFile(path: "a.docx", localExists: true, remoteExists: true)]
        repo.pausedForConflict = true
        try store.save(PersistedState(settings: settings, repositories: [repo]))

        let loaded = try XCTUnwrap(try store.load())
        XCTAssertEqual(loaded.settings.intervalMinutes, 17)
        XCTAssertTrue(loaded.settings.autoSyncEnabled)
        XCTAssertEqual(loaded.repositories, [repo])
    }

    func testTransientStatusIsNotRestored() throws {
        var repo = RepositoryConfig(path: "/tmp/x", displayName: "x")
        repo.lastStatus = .uploading
        let data = try JSONEncoder().encode(repo)
        let decoded = try JSONDecoder().decode(RepositoryConfig.self, from: data)
        XCTAssertEqual(decoded.lastStatus, .notSynced)
    }

    func testOldStateFileWithMissingKeysStillLoads() throws {
        let json = #"{"settings":{"intervalMinutes":3},"repositories":[{"id":"\#(UUID().uuidString)","path":"/tmp/a"}]}"#
        let state = try JSONDecoder().decode(PersistedState.self, from: Data(json.utf8))
        XCTAssertEqual(state.settings.intervalMinutes, 3)
        XCTAssertEqual(state.settings.ignorePatterns, IgnoreRules.defaultPatterns)
        XCTAssertEqual(state.repositories.first?.displayName, "a")
        XCTAssertEqual(state.repositories.first?.autoSyncEnabled, true)
    }

    func testIgnoreRulesBlockIsReplacedNotDuplicated() {
        let original = "# user rule\n*.log\n"
        let once = IgnoreRules.render(existing: original, patterns: [".DS_Store"])
        let twice = IgnoreRules.render(existing: once, patterns: [".DS_Store", "~$*"])
        XCTAssertTrue(twice.hasPrefix("# user rule\n*.log\n"))
        XCTAssertEqual(twice.components(separatedBy: IgnoreRules.beginMarker).count, 2)
        XCTAssertTrue(twice.contains("~$*"))
    }

    func testStatusParserHandlesRenamesAndUnicode() {
        let data = Data("R  新名字.txt\0旧名字.txt\0?? 报告 1.docx\0 M a/b.txt\0".utf8)
        let entries = StatusEntry.parse(data)
        XCTAssertEqual(entries.map(\.path), ["新名字.txt", "报告 1.docx", "a/b.txt"])
        XCTAssertEqual(entries.first?.originalPath, "旧名字.txt")
        XCTAssertTrue(entries[1].isUntracked)
    }
}
