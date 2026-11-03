import AppKit
import Foundation
import Observation

enum AuthSource: String, Codable, Sendable {
    case oauthApp, personalToken, githubCLI, systemHelper

    var displayName: String {
        switch self {
        case .oauthApp: "GitHub OAuth 授权"
        case .personalToken: "个人访问令牌"
        case .githubCLI: "GitHub CLI (gh)"
        case .systemHelper: "系统 Git 凭据助手"
        }
    }
}

enum AuthState: Equatable {
    case unknown
    case checking
    case signedIn(login: String, source: AuthSource)
    /// A credential exists but GitHub could not be reached to verify it.
    case unverified(source: AuthSource, detail: String)
    case signedOut
    case invalid(source: AuthSource, message: String)

    var isUsable: Bool {
        switch self {
        case .signedIn, .unverified: true
        default: false
        }
    }

    var summary: String {
        switch self {
        case .unknown: "尚未检测"
        case .checking: "正在检测 GitHub 登录状态…"
        case .signedIn(let login, let source): "已登录 \(login)（\(source.displayName)）"
        case .unverified(let source, _): "已找到凭据（\(source.displayName)），暂时无法验证"
        case .signedOut: "未登录 GitHub"
        case .invalid(_, let message): message
        }
    }
}

struct DeviceFlowSession: Equatable {
    var userCode: String
    var verificationURL: URL
    var expiresAt: Date
    var statusMessage: String
    var failed = false
}

/// Finds and verifies a GitHub credential, and hands it to git.
///
/// Order: the app's own token (OAuth Device Flow / PAT in Keychain) → GitHub CLI →
/// whatever the system git credential helper already has.
@MainActor
@Observable
final class GitHubAuthService {
    private(set) var state: AuthState = .unknown
    private(set) var user: GitHubUser?
    var deviceFlow: DeviceFlowSession?
    private(set) var ghPath: String?
    private(set) var ghLoggedIn = false
    private(set) var lastChecked: Date?

    @ObservationIgnored var gitEnvironment: GitEnvironment?
    @ObservationIgnored private var cachedGHToken: (token: String, at: Date)?
    @ObservationIgnored private var deviceFlowTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    var identity: GitIdentity? {
        guard let user else { return nil }
        return GitIdentity(name: user.name ?? user.login, email: user.noreplyEmail)
    }

    // MARK: - Detection

    func refresh() async {
        if let refreshTask {
            await refreshTask.value
            return
        }
        let task = Task { await performRefresh() }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func performRefresh() async {
        state = .checking
        ghPath = GitEnvironment.findExecutable(named: "gh")?.path
        defer { lastChecked = Date() }

        if let stored = KeychainStore.load() {
            await verify(token: stored.token, source: stored.source)
            return
        }

        if let token = await githubCLIToken(forceRefresh: true) {
            ghLoggedIn = true
            await verify(token: token, source: .githubCLI)
            return
        }
        ghLoggedIn = false

        if await systemHelperHasCredential() {
            return
        }

        user = nil
        state = .signedOut
    }

    private func verify(token: String, source: AuthSource) async {
        do {
            let user = try await GitHubAPI.fetchUser(token: token)
            self.user = user
            state = .signedIn(login: user.login, source: source)
        } catch let error as GitHubAPIError {
            if error.isNetwork {
                state = .unverified(source: source, detail: error.localizedDescription)
            } else {
                user = nil
                state = .invalid(source: source, message: "\(source.displayName)凭据已失效：\(error.localizedDescription)。请重新登录。")
            }
        } catch {
            state = .unverified(source: source, detail: error.localizedDescription)
        }
    }

    /// Asks the system credential helper for github.com without allowing any prompt.
    private func systemHelperHasCredential() async -> Bool {
        guard let git = gitEnvironment else { return false }
        let input = Data("protocol=https\nhost=github.com\n\n".utf8)
        guard let result = try? await ProcessRunner.run(
            executable: git.gitURL, arguments: ["credential", "fill"],
            environment: git.environment, stdin: input, timeout: 15
        ), result.succeeded else { return false }

        let password = result.stdout.split(separator: "\n")
            .first { $0.hasPrefix("password=") }
            .map { String($0.dropFirst("password=".count)) }
        guard let password, !password.isEmpty else { return false }
        // Verify it, but never store it: git keeps using the helper directly.
        await verify(token: password, source: .systemHelper)
        return true
    }

    private func githubCLIToken(forceRefresh: Bool = false) async -> String? {
        if !forceRefresh, let cached = cachedGHToken, Date().timeIntervalSince(cached.at) < 600 {
            return cached.token
        }
        guard let gh = GitEnvironment.findExecutable(named: "gh") else { return nil }
        guard let result = try? await ProcessRunner.run(
            executable: gh, arguments: ["auth", "token", "--hostname", "github.com"],
            environment: GitEnvironment.buildEnvironment(), timeout: 15
        ), result.succeeded else {
            cachedGHToken = nil
            return nil
        }
        let token = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return nil }
        cachedGHToken = (token, Date())
        return token
    }

    // MARK: - Credential for git

    /// Token to inject into git, or nil to let git use the system helper / SSH agent.
    func credentialForGit() async -> GitCredential? {
        let source: AuthSource? = switch state {
        case .signedIn(_, let source), .unverified(let source, _), .invalid(let source, _): source
        default: nil
        }
        switch source {
        case .oauthApp, .personalToken:
            return KeychainStore.load().map { GitCredential(token: $0.token) }
        case .githubCLI:
            return await githubCLIToken().map { GitCredential(token: $0) }
        case .systemHelper:
            return nil
        case nil:
            if let stored = KeychainStore.load() { return GitCredential(token: stored.token) }
            return await githubCLIToken().map { GitCredential(token: $0) }
        }
    }

    /// Called when git reports an authentication error.
    func handleGitAuthFailure() {
        cachedGHToken = nil
        Task { await refresh() }
    }

    // MARK: - Sign in / out

    func signIn(personalToken: String) async -> String? {
        let token = personalToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return "请输入令牌" }
        do {
            let user = try await GitHubAPI.fetchUser(token: token)
            try KeychainStore.save(.init(token: token, source: .personalToken))
            self.user = user
            state = .signedIn(login: user.login, source: .personalToken)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func startDeviceFlow(clientID: String) {
        let clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        cancelDeviceFlow()
        guard !clientID.isEmpty else {
            deviceFlow = DeviceFlowSession(
                userCode: "", verificationURL: URL(string: "https://github.com/settings/developers")!,
                expiresAt: Date(), statusMessage: "请先在设置中填写 OAuth App 的 Client ID（需要在 GitHub 开发者设置中启用 Device Flow）。",
                failed: true
            )
            return
        }
        deviceFlow = DeviceFlowSession(
            userCode: "…", verificationURL: URL(string: "https://github.com/login/device")!,
            expiresAt: Date().addingTimeInterval(900), statusMessage: "正在向 GitHub 申请授权码…"
        )
        deviceFlowTask = Task { await runDeviceFlow(clientID: clientID) }
    }

    private func runDeviceFlow(clientID: String) async {
        let code: DeviceCodeResponse
        do {
            code = try await GitHubAPI.requestDeviceCode(clientID: clientID)
        } catch {
            deviceFlow?.statusMessage = "申请授权码失败：\(error.localizedDescription)"
            deviceFlow?.failed = true
            return
        }
        let url = URL(string: code.verificationURI) ?? URL(string: "https://github.com/login/device")!
        deviceFlow = DeviceFlowSession(
            userCode: code.userCode, verificationURL: url,
            expiresAt: Date().addingTimeInterval(TimeInterval(code.expiresIn)),
            statusMessage: "请在浏览器中输入上面的验证码并授权，完成后此窗口会自动更新。"
        )
        NSWorkspace.shared.open(url)

        var interval = max(code.interval, 5)
        while !Task.isCancelled, let flow = deviceFlow, Date() < flow.expiresAt {
            try? await Task.sleep(for: .seconds(interval))
            if Task.isCancelled { return }
            switch await GitHubAPI.pollDeviceToken(clientID: clientID, deviceCode: code.deviceCode) {
            case .pending:
                continue
            case .slowDown(let newInterval):
                interval = max(newInterval, interval + 5)
            case .token(let token):
                do {
                    let user = try await GitHubAPI.fetchUser(token: token)
                    try KeychainStore.save(.init(token: token, source: .oauthApp))
                    self.user = user
                    state = .signedIn(login: user.login, source: .oauthApp)
                    deviceFlow = nil
                } catch {
                    deviceFlow?.statusMessage = "已获得令牌但保存/验证失败：\(error.localizedDescription)"
                    deviceFlow?.failed = true
                }
                return
            case .failed(let error):
                deviceFlow?.statusMessage = error.localizedDescription
                deviceFlow?.failed = true
                return
            }
        }
        if !Task.isCancelled, deviceFlow != nil {
            deviceFlow?.statusMessage = "验证码已过期，请重新开始。"
            deviceFlow?.failed = true
        }
    }

    func cancelDeviceFlow() {
        deviceFlowTask?.cancel()
        deviceFlowTask = nil
        deviceFlow = nil
    }

    /// Removes the app's own token. GitHub CLI and system credentials are left alone.
    func signOut() {
        KeychainStore.delete()
        user = nil
        Task { await refresh() }
    }

    var hasAppToken: Bool { KeychainStore.load() != nil }

    /// Opens Terminal with `gh auth login` (browser-based). Requires GitHub CLI.
    func openGitHubCLILogin() throws {
        guard let gh = GitEnvironment.findExecutable(named: "gh") else {
            throw NSError(domain: "GitSync", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "未找到 GitHub CLI。请先安装：brew install gh，或访问 https://cli.github.com 下载。",
            ])
        }
        let script = """
        #!/bin/zsh
        echo "GitSync — 登录 GitHub CLI"
        echo "将打开浏览器完成授权，完成后回到 GitSync 点击「重新检测」。"
        echo
        "\(gh.path)" auth login --hostname github.com --git-protocol https --web
        echo
        echo "完成。可以关闭此窗口。"
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gitcloud-gh-login.command")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        NSWorkspace.shared.open(url)
    }
}
