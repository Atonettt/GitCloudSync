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
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("添加仓库…") { RepositoryPicker.present(model: model) }
                    .keyboardShortcut("o")
            }
            CommandMenu("同步") {
                Button("立即同步全部") { model.syncAll(trigger: .manualAll) }
                    .keyboardShortcut("r")
                Button(model.settings.autoSyncEnabled ? "暂停自动同步" : "启动自动同步") {
                    model.settings.autoSyncEnabled ? model.pauseAutoSync() : model.startAutoSync()
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }

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
        panel.title = "选择 Git 仓库文件夹"
        panel.message = "选择一个或多个已通过 GitHub Desktop 克隆或发布的仓库文件夹"
        panel.prompt = "添加"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await model.addRepositories(urls: urls) }
    }
}
