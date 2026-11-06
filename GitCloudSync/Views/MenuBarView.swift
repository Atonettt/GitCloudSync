import SwiftUI

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let running = model.autoSyncCount > 0
        let total = model.repositories.count
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                AppIconView(size: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text("GitSync").font(.subheadline.weight(.semibold))
                    if running, let next = model.nextSyncDate {
                        Text("每 \(model.settings.intervalMinutes) 分钟 · 下次 \(next.formatted(date: .omitted, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if running, model.autoSyncCount < total {
                    Text("\(model.autoSyncCount)/\(total)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .help("\(total) 个仓库中有 \(model.autoSyncCount) 个开启了自动同步")
                }
                Toggle("自动同步", isOn: Binding(get: { running }, set: { model.setAutoSyncForAll($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(.green)
                    .fixedSize()
                    .help(running ? String(localized: "关闭后所有仓库暂停自动同步") : String(localized: "打开后所有仓库开启自动同步，并马上同步一次"))
                    .disabled(model.gitEnvironment == nil || total == 0)
            }

            Button {
                model.syncAll(trigger: .manualAll)
            } label: {
                Label("全部同步", systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .help("马上同步所有仓库，包括自动同步关闭的")
            .disabled(model.gitEnvironment == nil || total == 0)

            Divider()

            if model.repositories.isEmpty {
                Text("尚未添加仓库").foregroundStyle(.secondary).font(.callout)
            } else if total <= 6 {
                repositoryRows
            } else {
                // Many repositories: scroll inside a fixed height (a ScrollView has no height of its
                // own in the menu bar panel).
                ScrollView { repositoryRows }
                    .frame(height: 220)
            }

            Divider()

            HStack(spacing: 6) {
                MenuTileButton(title: String(localized: "主窗口"), symbol: "macwindow") { show(WindowID.main) }
                MenuTileButton(title: String(localized: "设置"), symbol: "gearshape") {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }
                MenuTileButton(title: String(localized: "退出"), symbol: "power") { NSApp.terminate(nil) }
            }
        }
        .padding(12)
        .frame(width: 290)
    }

    private var repositoryRows: some View {
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
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                Text(title).font(.caption2)
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(hovering ? 0.12 : 0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(title)
    }
}
