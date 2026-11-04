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
        .defaultSize(width: 920, height: 720)
        .windowStyle(.hiddenTitleBar)
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

        WindowGroup("版本历史", id: WindowID.history, for: UUID.self) { $repoID in
            if let repoID {
                HistoryView(repoID: repoID)
                    .environment(model)
            }
        }
        .defaultSize(width: 1000, height: 660)
        .windowStyle(.hiddenTitleBar)

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
            Image(systemName: model.menuBarSymbol)
        }
        .menuBarExtraStyle(.window)
    }
}

enum WindowID {
    static let main = "main"
    static let logs = "logs"
    static let history = "history"
}

final class AppDelegate: NSObject, NSApplicationDelegate {
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

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        true
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
