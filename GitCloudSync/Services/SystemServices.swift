import AppKit
import Foundation
import Network
import Observation
import ServiceManagement
import UserNotifications

/// Watches connectivity with NWPathMonitor.
final class NetworkMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.gitcloudsync.network")

    func start(onChange: @escaping @Sendable (Bool) -> Void) {
        monitor.pathUpdateHandler = { path in
            onChange(path.status == .satisfied)
        }
        monitor.start(queue: queue)
    }

    func stop() { monitor.cancel() }
}

/// macOS user notifications for failures, auth problems and conflicts.
@MainActor
final class NotificationService {
    private var authorized = false

    func requestAuthorization() {
        Task {
            let granted = (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])) ?? false
            authorized = granted
        }
    }

    func post(title: String, body: String, identifier: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}

/// "Open at login" via SMAppService (macOS 13+).
@MainActor
@Observable
final class LoginItemService {
    private(set) var isEnabled = false
    private(set) var statusText = ""

    init() { refresh() }

    func refresh() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled
        statusText = switch status {
        case .enabled: "已开启"
        case .notRegistered: "未开启"
        case .requiresApproval: "需要在「系统设置 › 通用 › 登录项」中允许"
        case .notFound: "未找到应用（请将 GitSync 放到“应用程序”文件夹后再开启）"
        @unknown default: "未知状态"
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        defer { refresh() }
        if enabled {
            try SMAppService.mainApp.register()
            if SMAppService.mainApp.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            }
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

/// In-memory log with debounced persistence to Application Support.
@MainActor
@Observable
final class LogStore {
    static let maxEntries = 3000

    private(set) var entries: [SyncLogEntry] = []
    @ObservationIgnored private let store = JSONFileStore<[SyncLogEntry]>(
        url: JSONFileStore<[SyncLogEntry]>.applicationSupportURL(fileName: "logs.json")
    )
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init() {
        entries = (try? store.load()) ?? []
    }

    func add(_ entry: SyncLogEntry) {
        entries.insert(entry, at: 0)
        if entries.count > Self.maxEntries {
            entries.removeLast(entries.count - Self.maxEntries)
        }
        scheduleSave()
    }

    func clear() {
        entries.removeAll()
        scheduleSave()
    }

    func flush() {
        saveTask?.cancel()
        try? store.save(entries)
    }

    var fileURL: URL { store.url }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            try? self.store.save(self.entries)
        }
    }
}
