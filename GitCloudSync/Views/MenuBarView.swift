import SwiftUI

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let running = model.settings.autoSyncEnabled
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: model.menuBarSymbol).foregroundStyle(.tint)
                Text("GitCloud Sync").font(.headline)
                Spacer()
                Text(model.overallStatusText).font(.caption).foregroundStyle(.secondary)
            }
            if running, let next = model.nextSyncDate {
                Text("每 \(model.settings.intervalMinutes) 分钟 · 下次 \(next.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Button {
                    running ? model.pauseAutoSync() : model.startAutoSync()
                } label: {
                    Label(running ? "暂停自动同步" : "启动自动同步", systemImage: running ? "pause.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(running ? .orange : .green)
                Button {
                    model.syncAll(trigger: .manualAll)
                } label: {
                    Label("立即同步", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
            }
            .disabled(model.gitEnvironment == nil)

            Divider()

            if model.repositories.isEmpty {
                Text("尚未添加仓库").foregroundStyle(.secondary).font(.callout)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.repositories) { repo in
                            let status = model.displayStatus(for: repo)
                            HStack(spacing: 8) {
                                if status.isActive {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Image(systemName: status.symbol).foregroundStyle(status.color)
                                }
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(repo.displayName).lineLimit(1)
                                    Text(status.displayName + (repo.lastSyncAt.map { " · \($0.relativeDescription)" } ?? ""))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    model.sync(repo.id, trigger: .manualSingle)
                                } label: { Image(systemName: "arrow.triangle.2.circlepath") }
                                    .buttonStyle(.borderless)
                                    .disabled(model.runtime[repo.id]?.isSyncing == true)
                                    .help("立即同步")
                            }
                        }
                    }
                }
                .frame(maxHeight: 240)
            }

            Divider()

            HStack {
                Button("打开主窗口") { show(WindowID.main) }
                Button("日志") { show(WindowID.logs) }
                Button("设置") {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }
                Spacer()
                Button("退出") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 340)
    }

    private func show(_ id: String) {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: id)
    }
}
