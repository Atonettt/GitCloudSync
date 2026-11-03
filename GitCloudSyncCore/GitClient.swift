import Foundation

/// A GitHub token handed to git for HTTPS remotes on github.com.
public struct GitCredential: Sendable, Equatable {
    public let username: String
    public let token: String

    public init(username: String = "x-access-token", token: String) {
        self.username = username
        self.token = token
    }
}

/// Runs git inside one repository with a safe environment.
public struct GitClient: Sendable {
    public let repositoryURL: URL
    public let git: GitEnvironment
    public let credential: GitCredential?

    static let tokenEnvKey = "GITCLOUD_SYNC_TOKEN"
    static let userEnvKey = "GITCLOUD_SYNC_USER"

    public init(repositoryURL: URL, git: GitEnvironment, credential: GitCredential? = nil) {
        self.repositoryURL = repositoryURL
        self.git = git
        self.credential = credential
    }

    /// `-c` options prepended to every command.
    ///
    /// When the app owns a token, the github.com credential helper list is reset and replaced
    /// by an inline helper that reads the token from the environment. The token therefore never
    /// appears in argv (visible in `ps`) or on disk, and existing helpers that might prompt are
    /// bypassed for github.com only.
    var configArguments: [String] {
        var args = ["-c", "core.quotepath=false", "-c", "color.ui=never", "-c", "advice.detachedHead=false"]
        if credential != nil {
            let helper = "!f() { if [ \"$1\" = get ]; then printf 'username=%s\\npassword=%s\\n' \"$\(Self.userEnvKey)\" \"$\(Self.tokenEnvKey)\"; fi; }; f"
            args += [
                "-c", "credential.https://github.com.helper=",
                "-c", "credential.https://github.com.helper=\(helper)",
            ]
        }
        return args
    }

    var environment: [String: String] {
        var env = git.environment
        if let credential {
            env[Self.tokenEnvKey] = credential.token
            env[Self.userEnvKey] = credential.username
        }
        return env
    }

    public func run(
        _ arguments: [String],
        timeout: TimeInterval = 60,
        stdin: Data? = nil,
        extraConfig: [String] = []
    ) async throws -> ProcessResult {
        try await ProcessRunner.run(
            executable: git.gitURL,
            arguments: configArguments + extraConfig + arguments,
            currentDirectory: repositoryURL,
            environment: environment,
            stdin: stdin,
            timeout: timeout
        )
    }
}
