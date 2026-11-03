import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HeaderView()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let problem = model.gitProblem {
                        ProblemBanner(title: "未找到可用的 Git", message: problem, symbol: "wrench.and.screwdriver")
                    }
                    GlobalControlsView()
                    RepositoryListView()
                }
                .padding(20)
            }
            Divider()
            ActivityFooterView()
        }
        .frame(minWidth: 780, minHeight: 560)
        .sheet(item: $model.activeSheet) { sheet in
            switch sheet {
            case .errorDetail(let id): ErrorDetailView(repoID: id)
            case .conflicts(let id): ConflictResolutionView(repoID: id)
            case .deviceFlow: DeviceFlowView()
            }
        }
        .alert(item: $model.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("好")))
        }
    }
}

struct HeaderView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 12) {
            AppIconView(size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("GitSync").font(.title2.bold())
                AuthStatusLabel()
            }
            Spacer()
            Button {
                openSettings()
            } label: {
                Label("设置", systemImage: "gearshape")
            }
            Button {
                RepositoryPicker.present(model: model)
            } label: {
                Label("添加仓库", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.gitEnvironment == nil)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

struct AuthStatusLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let state = model.auth.state
        HStack(spacing: 6) {
            Circle()
                .fill(color(for: state))
                .frame(width: 7, height: 7)
            Text(state.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if !state.isUsable, state != .checking {
                Button("登录 GitHub") { openSettings() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }

    private func color(for state: AuthState) -> Color {
        switch state {
        case .signedIn: .green
        case .unverified: .yellow
        case .checking, .unknown: .gray
        case .signedOut, .invalid: .orange
        }
    }
}

struct GlobalControlsView: View {
    @Environment(AppModel.self) private var model
    @State private var customMinutes = 20
    @State private var showCustom = false

    var body: some View {
        let running = model.settings.autoSyncEnabled
        HStack(alignment: .center, spacing: 18) {
            Button {
                running ? model.pauseAutoSync() : model.startAutoSync()
            } label: {
                Label(running ? "暂停自动同步" : "启动自动同步",
                      systemImage: running ? "pause.circle.fill" : "play.circle.fill")
                    .font(.headline)
                    .frame(minWidth: 150)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(running ? .orange : .green)
            .controlSize(.large)
            .disabled(model.gitEnvironment == nil)

            Button {
                model.syncAll(trigger: .manualAll)
            } label: {
                Label("立即同步", systemImage: "arrow.triangle.2.circlepath")
                    .padding(.vertical, 4)
            }
            .controlSize(.large)
            .disabled(model.repositories.isEmpty || model.gitEnvironment == nil)

            Divider().frame(height: 36)

            VStack(alignment: .leading, spacing: 4) {
                Text("同步间隔").font(.caption).foregroundStyle(.secondary)
                intervalMenu
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(running ? (model.isOnline ? Color.green : Color.gray) : Color.secondary)
                        .frame(width: 8, height: 8)
                    Text(model.overallStatusText).font(.callout.weight(.medium))
                }
                if running, let next = model.nextSyncDate {
                    Text("下次同步：\(next.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                } else if !running {
                    Text("点击「启动自动同步」后按间隔自动同步")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .popover(isPresented: $showCustom) {
            VStack(alignment: .leading, spacing: 12) {
                Text("自定义同步间隔").font(.headline)
                Stepper(value: $customMinutes, in: 1...1440) {
                    HStack {
                        TextField("分钟", value: $customMinutes, format: .number)
                            .frame(width: 70)
                            .textFieldStyle(.roundedBorder)
                        Text("分钟")
                    }
                }
                HStack {
                    Spacer()
                    Button("取消") { showCustom = false }
                    Button("应用") {
                        model.setInterval(minutes: customMinutes)
                        showCustom = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
            .frame(width: 260)
        }
    }

    private var intervalMenu: some View {
        Menu {
            ForEach(AppSettings.presetIntervals, id: \.self) { minutes in
                Button {
                    model.setInterval(minutes: minutes)
                } label: {
                    if model.settings.intervalMinutes == minutes {
                        Label(label(minutes), systemImage: "checkmark")
                    } else {
                        Text(label(minutes))
                    }
                }
            }
            Divider()
            Button("自定义…") {
                customMinutes = model.settings.intervalMinutes
                showCustom = true
            }
        } label: {
            Text("每 \(label(model.settings.intervalMinutes))")
        }
        .fixedSize()
    }

    private func label(_ minutes: Int) -> String {
        minutes == 60 ? "60 分钟（1 小时）" : "\(minutes) 分钟"
    }
}

struct RepositoryListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("仓库").font(.headline)
                Text("\(model.repositories.count)")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                Spacer()
            }
            if model.repositories.isEmpty {
                EmptyRepositoriesView()
            } else {
                ForEach(model.repositories) { repo in
                    RepositoryCardView(repo: repo)
                }
            }
        }
    }
}

struct EmptyRepositoriesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("还没有仓库").font(.title3.bold())
            Text("添加已经通过 GitHub Desktop 发布到 GitHub 的本地仓库文件夹，\n然后点击「启动自动同步」。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("添加仓库…") { RepositoryPicker.present(model: model) }
                .buttonStyle(.borderedProminent)
                .disabled(model.gitEnvironment == nil)
        }
        .frame(maxWidth: .infinity)
        .padding(40)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct ProblemBanner: View {
    let title: String
    let message: String
    let symbol: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(message).font(.callout).textSelection(.enabled)
            }
            Spacer()
        }
        .padding(12)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct ActivityFooterView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
            if let latest = model.logStore.entries.first {
                Image(systemName: latest.level.symbol).foregroundStyle(latest.level.color)
                Text("\(latest.date.formatted(date: .omitted, time: .standard))  \(latest.result)")
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .font(.callout)
            } else {
                Text("暂无同步活动").foregroundStyle(.secondary)
            }
            Spacer()
            let errors = model.repositories.filter { $0.lastStatus.isProblem }.count
            if errors > 0 {
                Label("\(errors) 个仓库需要处理", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
            Button("查看全部日志") { openWindow(id: WindowID.logs) }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }
}
