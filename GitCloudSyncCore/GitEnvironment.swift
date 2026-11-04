import Foundation

/// Where git lives and the environment every git call runs with.
///
/// Apps launched from Finder or Xcode get a minimal PATH (no /opt/homebrew/bin) and no
/// terminal. This type fixes PATH and turns every interactive prompt off, so a missing
/// credential produces an error instead of a hung process.
public struct GitEnvironment: Sendable, Equatable {
    public let gitURL: URL
    public let version: String
    public let environment: [String: String]

    public static let searchPaths = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ]

    public init(gitURL: URL, version: String, environment: [String: String]) {
        self.gitURL = gitURL
        self.version = version
        self.environment = environment
    }

    public static func buildEnvironment(
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var env = base
        let existing = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        env["PATH"] = (searchPaths + existing.filter { !searchPaths.contains($0) }).joined(separator: ":")
        if env["HOME"]?.isEmpty ?? true { env["HOME"] = NSHomeDirectory() }

        // Never wait for input.
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GCM_INTERACTIVE"] = "never"
        env["GH_PROMPT_DISABLED"] = "1"
        env["GIT_EDITOR"] = "true"
        env["GIT_MERGE_AUTOEDIT"] = "no"
        env.removeValue(forKey: "GIT_ASKPASS")
        env.removeValue(forKey: "SSH_ASKPASS")
        if env["GIT_SSH_COMMAND"] == nil {
            env["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes -o ConnectTimeout=20"
        }

        // Abort transfers that stall (< 1 KB/s for 60 s).
        env["GIT_HTTP_LOW_SPEED_LIMIT"] = "1000"
        env["GIT_HTTP_LOW_SPEED_TIME"] = "60"

        // Avoid fighting GitHub Desktop over index.lock for read-only commands.
        env["GIT_OPTIONAL_LOCKS"] = "0"

        // English messages so errors can be classified reliably; UTF-8 for file names.
        env["LANG"] = "en_US.UTF-8"
        env["LC_ALL"] = "en_US.UTF-8"
        env.removeValue(forKey: "LANGUAGE")

        // Xcode injects dylib overrides that must not leak into git.
        for key in env.keys where key.hasPrefix("DYLD_") {
            env.removeValue(forKey: key)
        }
        return env
    }

    public static func candidatePaths(customPath: String?) -> [String] {
        var paths: [String] = []
        if let customPath, !customPath.trimmingCharacters(in: .whitespaces).isEmpty {
            paths.append((customPath as NSString).expandingTildeInPath)
        }
        paths += searchPaths.map { "\($0)/git" }
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    /// Finds a working git. `/usr/bin/git` is the Xcode shim and only works when the
    /// Command Line Tools or Xcode are installed, so every candidate is actually executed.
    public static func detect(customPath: String? = nil) async -> Result<GitEnvironment, GitDetectionError> {
        let env = buildEnvironment()
        var attempts: [String] = []
        for path in candidatePaths(customPath: customPath) {
            guard FileManager.default.isExecutableFile(atPath: path) else { continue }
            let url = URL(fileURLWithPath: path)
            do {
                let result = try await ProcessRunner.run(
                    executable: url, arguments: ["--version"], environment: env, timeout: 20
                )
                if result.succeeded, result.stdout.hasPrefix("git version") {
                    let version = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    return .success(GitEnvironment(gitURL: url, version: version, environment: env))
                }
                attempts.append(String(localized: "\(path): 退出码 \(result.exitCode) \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"))
            } catch {
                attempts.append("\(path): \(error.localizedDescription)")
            }
        }
        return .failure(GitDetectionError(attempts: attempts))
    }

    /// Locates another command-line tool (e.g. `gh`) on the corrected PATH.
    public static func findExecutable(named name: String) -> URL? {
        let path = buildEnvironment()["PATH"] ?? ""
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }
}

public struct GitDetectionError: Error, LocalizedError, Sendable {
    public let attempts: [String]
    public var errorDescription: String? {
        var text = String(localized: "未找到可用的 Git。请安装 Xcode Command Line Tools（终端执行 xcode-select --install）或 Homebrew Git（brew install git）。")
        if !attempts.isEmpty {
            text += String(localized: "\n\n尝试记录：\n") + attempts.joined(separator: "\n")
        }
        return text
    }
}
