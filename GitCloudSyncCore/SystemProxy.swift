import CFNetwork
import Foundation

/// The proxy set in macOS network settings (for example by Clash or Surge), as the environment
/// variables git's libcurl understands. git ignores the system settings on its own, so without
/// this GitSync connects to GitHub directly even when every other app goes through the proxy.
public enum SystemProxy {
    static let variableNames = ["https_proxy", "HTTPS_PROXY", "http_proxy", "HTTP_PROXY", "all_proxy", "ALL_PROXY"]

    /// Variables for the current system settings; empty when no proxy is on.
    public static func environment() -> [String: String] {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else { return [:] }
        return environment(from: settings)
    }

    /// Adds the system proxy to `base` unless it already names a proxy (then that one wins).
    public static func applying(to base: [String: String], settings: [String: Any]? = nil) -> [String: String] {
        if variableNames.contains(where: { !(base[$0] ?? "").isEmpty }) { return base }
        let proxy = settings.map(environment(from:)) ?? environment()
        return base.merging(proxy) { current, _ in current }
    }

    /// Maps the dictionary from `CFNetworkCopySystemProxySettings`. Automatic proxy configuration
    /// (PAC files) is not evaluated.
    public static func environment(from settings: [String: Any]) -> [String: String] {
        func server(_ prefix: String) -> (host: String, port: Int)? {
            guard (settings["\(prefix)Enable"] as? NSNumber)?.boolValue == true,
                  let host = settings["\(prefix)Proxy"] as? String, !host.isEmpty,
                  let port = (settings["\(prefix)Port"] as? NSNumber)?.intValue, port > 0 else { return nil }
            return (host, port)
        }
        var env: [String: String] = [:]
        if let https = server("HTTPS") ?? server("HTTP") {
            env["https_proxy"] = "http://\(https.host):\(https.port)"
            env["HTTPS_PROXY"] = env["https_proxy"]
        }
        if let http = server("HTTP") ?? server("HTTPS") {
            env["http_proxy"] = "http://\(http.host):\(http.port)"
            env["HTTP_PROXY"] = env["http_proxy"]
        }
        if env.isEmpty, let socks = server("SOCKS") {
            // socks5h: the proxy resolves host names, as it does for other apps.
            env["all_proxy"] = "socks5h://\(socks.host):\(socks.port)"
            env["ALL_PROXY"] = env["all_proxy"]
        }
        guard !env.isEmpty else { return [:] }

        var bypass = ["localhost", "127.0.0.1", "::1"]
        for entry in settings["ExceptionsList"] as? [String] ?? [] {
            // curl matches a bare domain and its subdomains; "*.local" becomes ".local".
            let item = entry.hasPrefix("*.") ? String(entry.dropFirst()) : entry
            if !item.isEmpty, !item.contains("*"), !item.contains("<"), !bypass.contains(item) { bypass.append(item) }
        }
        env["no_proxy"] = bypass.joined(separator: ",")
        env["NO_PROXY"] = env["no_proxy"]
        return env
    }
}
