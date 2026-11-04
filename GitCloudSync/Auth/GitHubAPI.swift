import Foundation

struct GitHubUser: Decodable, Sendable {
    let login: String
    let id: Int
    let name: String?

    var noreplyEmail: String { "\(id)+\(login)@users.noreply.github.com" }
}

struct CreatedRepository: Decodable, Sendable {
    let fullName: String
    let cloneURL: String
    let htmlURL: URL

    enum CodingKeys: String, CodingKey {
        case fullName = "full_name"
        case cloneURL = "clone_url"
        case htmlURL = "html_url"
    }
}

enum GitHubAPIError: Error, LocalizedError {
    case unauthorized
    case nameTaken
    case missingDeleteScope
    case notFound
    case cannotCreate(String)
    case http(Int, String)
    case network(String)
    case oauth(String, String?)

    var errorDescription: String? {
        switch self {
        case .unauthorized: String(localized: "令牌无效或已过期（HTTP 401）")
        case .nameTaken: String(localized: "你的 GitHub 账号下已经有同名仓库")
        case .missingDeleteScope: String(localized: "当前登录的令牌没有删除仓库的权限（delete_repo）")
        case .notFound: String(localized: "GitHub 上找不到这个仓库")
        case .cannotCreate(let detail): String(localized: "当前登录的令牌没有创建仓库的权限（\(detail)）。请用 GitHub CLI 登录，或使用带 repo 权限的经典令牌。")
        case .http(let code, let body): String(localized: "GitHub 返回 HTTP \(code)：\(body.prefix(300))")
        case .network(let message): String(localized: "无法连接 GitHub：\(message)")
        case .oauth(let code, let description): String(localized: "授权失败：\(description ?? code)（\(code)）")
        }
    }

    var isNetwork: Bool {
        if case .network = self { return true }
        return false
    }
}

struct DeviceCodeResponse: Decodable, Sendable {
    let deviceCode: String
    let userCode: String
    let verificationURI: String
    let expiresIn: Int
    let interval: Int

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURI = "verification_uri"
        case expiresIn = "expires_in"
        case interval
    }
}

enum DevicePollResult: Sendable {
    case token(String)
    case pending
    case slowDown(Int)
    case failed(GitHubAPIError)
}

/// Minimal GitHub REST + OAuth Device Flow client.
enum GitHubAPI {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 40
        return URLSession(configuration: config)
    }()

    static func fetchUser(token: String) async throws -> GitHubUser {
        var request = URLRequest(url: URL(string: "https://api.github.com/user")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("GitSync", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await perform(request)
        switch response.statusCode {
        case 200: return try JSONDecoder().decode(GitHubUser.self, from: data)
        case 401: throw GitHubAPIError.unauthorized
        default: throw GitHubAPIError.http(response.statusCode, String(decoding: data, as: UTF8.self))
        }
    }

    /// Creates a repository under the signed-in account. https://docs.github.com/rest/repos/repos#create-a-repository-for-the-authenticated-user
    static func createRepository(token: String, name: String, isPrivate: Bool, description: String) async throws -> CreatedRepository {
        var request = URLRequest(url: URL(string: "https://api.github.com/user/repos")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("GitSync", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["name": name, "private": isPrivate, "auto_init": false]
        if !description.isEmpty { body["description"] = description }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await perform(request)
        let text = String(decoding: data, as: UTF8.self)
        switch response.statusCode {
        case 201: return try JSONDecoder().decode(CreatedRepository.self, from: data)
        case 401: throw GitHubAPIError.unauthorized
        case 422 where text.contains("already exists"): throw GitHubAPIError.nameTaken
        case 403, 404: throw GitHubAPIError.cannotCreate("HTTP \(response.statusCode)")
        default: throw GitHubAPIError.http(response.statusCode, text)
        }
    }

    /// Permanently deletes a repository. Needs the `delete_repo` scope (classic tokens, GitHub CLI)
    /// or Administration write access (fine-grained tokens).
    static func deleteRepository(token: String, owner: String, name: String) async throws {
        var components = URLComponents(string: "https://api.github.com")!
        components.path = "/repos/\(owner)/\(name)"
        var request = URLRequest(url: components.url!)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("GitSync", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await perform(request)
        switch response.statusCode {
        case 204: return
        case 401: throw GitHubAPIError.unauthorized
        case 403: throw GitHubAPIError.missingDeleteScope
        case 404: throw GitHubAPIError.notFound
        default: throw GitHubAPIError.http(response.statusCode, String(decoding: data, as: UTF8.self))
        }
    }

    /// Step 1 of the Device Flow: https://docs.github.com/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps#device-flow
    static func requestDeviceCode(clientID: String, scope: String = "repo") async throws -> DeviceCodeResponse {
        let (data, response) = try await postForm(
            "https://github.com/login/device/code",
            ["client_id": clientID, "scope": scope]
        )
        guard response.statusCode == 200 else {
            throw GitHubAPIError.http(response.statusCode, String(decoding: data, as: UTF8.self))
        }
        if let error = try? JSONDecoder().decode(OAuthError.self, from: data), error.error != nil {
            throw GitHubAPIError.oauth(error.error ?? "unknown", error.errorDescription)
        }
        return try JSONDecoder().decode(DeviceCodeResponse.self, from: data)
    }

    /// Step 3: poll for the token.
    static func pollDeviceToken(clientID: String, deviceCode: String) async -> DevicePollResult {
        do {
            let (data, response) = try await postForm(
                "https://github.com/login/oauth/access_token",
                [
                    "client_id": clientID,
                    "device_code": deviceCode,
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                ]
            )
            guard response.statusCode == 200 else {
                return .failed(.http(response.statusCode, String(decoding: data, as: UTF8.self)))
            }
            let payload = try JSONDecoder().decode(TokenPayload.self, from: data)
            if let token = payload.accessToken, !token.isEmpty { return .token(token) }
            switch payload.error {
            case "authorization_pending": return .pending
            case "slow_down": return .slowDown(payload.interval ?? 10)
            default: return .failed(.oauth(payload.error ?? "unknown", payload.errorDescription))
            }
        } catch let error as GitHubAPIError {
            return .failed(error)
        } catch {
            return .failed(.network(error.localizedDescription))
        }
    }

    private struct OAuthError: Decodable {
        let error: String?
        let errorDescription: String?
        enum CodingKeys: String, CodingKey {
            case error
            case errorDescription = "error_description"
        }
    }

    private struct TokenPayload: Decodable {
        let accessToken: String?
        let error: String?
        let errorDescription: String?
        let interval: Int?
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case error
            case errorDescription = "error_description"
            case interval
        }
    }

    private static func postForm(_ urlString: String, _ fields: [String: String]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: URL(string: urlString)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("GitSync", forHTTPHeaderField: "User-Agent")
        var components = URLComponents()
        components.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        return try await perform(request)
    }

    private static func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw GitHubAPIError.network(String(localized: "无效响应"))
            }
            return (data, http)
        } catch let error as GitHubAPIError {
            throw error
        } catch {
            throw GitHubAPIError.network(error.localizedDescription)
        }
    }
}
