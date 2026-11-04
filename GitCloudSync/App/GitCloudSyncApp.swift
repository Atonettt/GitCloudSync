import AppKit
import SwiftUI

@main
struct GitCloudSyncApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("GitSync", id: WindowID.main) {
            MainView()
                .environment(model)
        }
        .defaultSize(width: 1040, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("添加仓库…") { RepositoryPicker.present(model: model) }
                    .keyboardShortcut("o")
            }
            CommandMenu("同步") {
                Button("立即同步全部") { model.syncAll(trigger: .manualAll) }
                    .keyboardShortcut("r")
                Button(model.autoSyncCount > 0 ? String(localized: "全部暂停自动同步") : String(localized: "全部开启自动同步")) {
                    model.setAutoSyncForAll(model.autoSyncCount == 0)
                }
                .disabled(model.repositories.isEmpty)
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }

        WindowGroup("版本历史", id: WindowID.history, for: HistoryRequest.self) { $request in
            if let request {
                HistoryView(request: request)
                    .environment(model)
            }
        }
        .defaultSize(width: 1280, height: 780)

        Window("同步日志", id: WindowID.logs) {
            LogsView()
                .environment(model)
        }
        .defaultSize(width: 980, height: 620)

        Settings {
            SettingsView()
                .environment(model)
        }

        MenuBarExtra {
            MenuBarView()
                .environment(model)
        } label: {
            MenuBarLabel(badge: model.menuBarBadge)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The menu bar icon. It is always on screen, so it also listens for requests to show the main
/// window (for example a click on the Dock icon when no window is open).
private struct MenuBarLabel: View {
    @Environment(\.openWindow) private var openWindow
    let badge: String

    var body: some View {
        Image(nsImage: MenuBarIcon.image(badge: badge))
            .onReceive(NotificationCenter.default.publisher(for: .showMainWindow)) { _ in
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: WindowID.main)
            }
    }
}

/// The app icon's cat in one colour with a small status badge in the corner, like the sync badge
/// on the app icon. It's a template image, so it follows the light or dark menu bar.
@MainActor
enum MenuBarIcon {
    private static var cache: [String: NSImage] = [:]

    static func image(badge: String) -> NSImage {
        if let cached = cache[badge] { return cached }
        let size = NSSize(width: 21, height: 18)
        let scale = 3
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSImage(named: "MenuBarCat")?.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
        // Clear a ring around the badge so it stands apart from the cat, as on the app icon.
        let center = NSPoint(x: 15.5, y: 5)
        NSGraphicsContext.current?.compositingOperation = .clear
        NSBezierPath(ovalIn: NSRect(x: center.x - 5.5, y: center.y - 5.5, width: 11, height: 11)).fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
        if let symbol = NSImage(systemSymbolName: badge, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 7.5, weight: .heavy)) {
            let s = symbol.size
            symbol.draw(in: NSRect(x: center.x - s.width / 2, y: center.y - s.height / 2, width: s.width, height: s.height))
        }
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: size)
        image.addRepresentation(rep)
        image.isTemplate = true
        cache[badge] = image
        return image
    }
}

extension Notification.Name {
    static let showMainWindow = Notification.Name("GitSyncShowMainWindow")
}

enum WindowID {
    static let main = "main"
    static let logs = "logs"
    static let history = "history"
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Keep every window separate even when macOS is set to "prefer tabs: always"; otherwise
        // version history opens as a tab of the main window and closing it closes both.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppModel.shared.start()
    }

    /// Closing the window keeps the app (and syncing) alive in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = AppModel.shared
        guard !model.isShuttingDown else { return .terminateNow }
        Task { @MainActor in
            await model.prepareForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Clicking the Dock icon with no window open shows the main window (not a version-history window).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        NotificationCenter.default.post(name: .showMainWindow, object: nil)
        return false
    }
}

/// Folder picker for adding repositories.
@MainActor
enum RepositoryPicker {
    static func present(model: AppModel) {
        let panel = NSOpenPanel()
        panel.title = String(localized: "选择要同步的文件夹")
        panel.message = String(localized: "可以选已发布到 GitHub 的仓库，也可以选普通文件夹（将在 GitHub 上创建新仓库）")
        panel.prompt = String(localized: "添加")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await model.addRepositories(urls: urls) }
    }
}
