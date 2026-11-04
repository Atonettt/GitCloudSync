import SwiftUI

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let running = model.autoSyncCount > 0
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                AppIconView(size: 22)
                Text("GitSync").font(.headline)
                Spacer()
                Text(model.overallStatusText).font(.caption).foregroundStyle(.secondary)
            }
            if running, let next = model.nextSyncDate {
                Text("每 \(model.settings.intervalMinutes) 分钟 · 下次 \(next.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Button {
                    model.syncAll(trigger: .manualAll)
                } label: {
                    Label("立即同步全部", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button {
                    model.setAutoSyncForAll(!running)
                } label: {
                    Label(running ? String(localized: "全部暂停") : String(localized: "全部开启"), systemImage: running ? "pause.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .help(running ? String(localized: "关闭所有仓库的自动同步开关") : String(localized: "打开所有仓库的自动同步开关并立即同步"))
            }
            .disabled(model.gitEnvironment == nil || model.repositories.isEmpty)

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
                // A ScrollView has no height of its own in the menu bar panel; size it to the rows.
                .frame(height: min(CGFloat(model.repositories.count) * 40, 240))
            }

            Divider()

            HStack(spacing: 6) {
                MenuTileButton(title: String(localized: "主窗口"), symbol: "macwindow") { show(WindowID.main) }
                MenuTileButton(title: String(localized: "日志"), symbol: "list.bullet.rectangle") { show(WindowID.logs) }
                MenuTileButton(title: String(localized: "设置"), symbol: "gearshape") {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }
                MenuTileButton(title: String(localized: "退出"), symbol: "power") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    private func show(_ id: String) {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: id)
    }
}

/// An icon-over-label tile with a visible resting background and a hover highlight, so it reads
/// as clickable (plain borderless text in the menu bar panel looked disabled).
private struct MenuTileButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 15, weight: .medium))
                Text(title).font(.caption)
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(hovering ? 0.12 : 0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(title)
    }
}
