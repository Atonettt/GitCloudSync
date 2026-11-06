import XCTest

final class SystemProxyTests: XCTestCase {
    /// What Clash Verge sets: HTTP, HTTPS and SOCKS on one mixed port.
    private let clash: [String: Any] = [
        "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 7897,
        "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 7897,
        "SOCKSEnable": 1, "SOCKSProxy": "127.0.0.1", "SOCKSPort": 7897,
        "ExceptionsList": ["*.local", "169.254/16", "localhost", "<local>"],
    ]

    func testHTTPProxyIsPassedToGit() {
        let env = SystemProxy.environment(from: clash)
        XCTAssertEqual(env["https_proxy"], "http://127.0.0.1:7897")
        XCTAssertEqual(env["HTTPS_PROXY"], "http://127.0.0.1:7897")
        XCTAssertEqual(env["http_proxy"], "http://127.0.0.1:7897")
        XCTAssertNil(env["all_proxy"], "SOCKS is only a fallback")
        XCTAssertEqual(env["no_proxy"], "localhost,127.0.0.1,::1,.local,169.254/16")
    }

    func testSocksOnly() {
        let env = SystemProxy.environment(from: ["SOCKSEnable": 1, "SOCKSProxy": "127.0.0.1", "SOCKSPort": 1080])
        XCTAssertEqual(env["all_proxy"], "socks5h://127.0.0.1:1080")
        XCTAssertNil(env["https_proxy"])
    }

    func testNoProxyWhenOff() {
        XCTAssertEqual(SystemProxy.environment(from: ["HTTPSEnable": 0, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 7897]), [:])
        XCTAssertEqual(SystemProxy.environment(from: [:]), [:])
    }

    func testExistingProxyVariablesWin() {
        let base = ["PATH": "/usr/bin", "HTTPS_PROXY": "http://corp:8080"]
        XCTAssertEqual(SystemProxy.applying(to: base, settings: clash), base)
        let applied = SystemProxy.applying(to: ["PATH": "/usr/bin"], settings: clash)
        XCTAssertEqual(applied["PATH"], "/usr/bin")
        XCTAssertEqual(applied["https_proxy"], "http://127.0.0.1:7897")
    }
}
