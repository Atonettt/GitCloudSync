import AppKit
import Foundation

/// The interface language, chosen in Settings. macOS reads `AppleLanguages` from the app's own
/// defaults at launch, so a change takes effect after GitSync restarts.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case chinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: String(localized: "跟随系统")
        // Each language is named in itself so it can be found whatever the current language is.
        case .chinese: "简体中文"
        case .english: "English"
        }
    }

    private static let key = "AppleLanguages"

    /// The saved choice (an override in GitSync's own defaults, not the system-wide list).
    static var saved: AppLanguage {
        let domain = Bundle.main.bundleIdentifier.flatMap { UserDefaults.standard.persistentDomain(forName: $0) }
        guard let first = (domain?[key] as? [String])?.first else { return .system }
        return first.hasPrefix("zh") ? .chinese : first.hasPrefix("en") ? .english : .system
    }

    /// The choice the running app was launched with.
    static let atLaunch = saved

    func save() {
        if self == .system {
            UserDefaults.standard.removeObject(forKey: Self.key)
        } else {
            UserDefaults.standard.set([rawValue], forKey: Self.key)
        }
    }

    /// Quits normally (waiting for running syncs) and opens GitSync again once it has exited.
    @MainActor
    static func relaunch() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }
}
