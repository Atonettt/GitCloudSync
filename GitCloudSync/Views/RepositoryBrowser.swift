import SwiftUI

/// How the repository list is ordered. Manual order is the one the user drags into place.
enum RepositorySort: String, CaseIterable, Identifiable {
    case manual, name, lastSync, problemsFirst

    var id: String { rawValue }

    var title: String {
        switch self {
        case .manual: String(localized: "手动排序")
        case .name: String(localized: "按名称")
        case .lastSync: String(localized: "按最近同步")
        case .problemsFirst: String(localized: "有问题的排在前面")
        }
    }
}

enum RepositoryFilter: String, CaseIterable, Identifiable {
    case all, autoSyncOn, autoSyncOff, attention

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: String(localized: "全部")
        case .autoSyncOn: String(localized: "自动同步中")
        case .autoSyncOff: String(localized: "已暂停")
        case .attention: String(localized: "需要处理")
        }
    }
}

/// The main window: a native sidebar with every repository, the selected one's details beside it,
/// and the global actions in the toolbar.
struct RepositoryBrowser: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @AppStorage("repositoryList.selection") private var selectionID = ""
    @AppStorage("repositoryList.sort") private var sort = RepositorySort.manual
    @AppStorage("repositoryList.filter") private var filter = RepositoryFilter.all
    @State private var search = ""

    var body: some View {
        let visible = visibleRepositories
        NavigationSplitView {
            sidebar(visible)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                if let problem = model.gitProblem {
                    ProblemBanner(title: String(localized: "未找到可用的 Git"), message: problem, symbol: "wrench.and.screwdriver")
                        .padding([.horizontal, .top], 24)
                }
                if model.repositories.isEmpty {
                    ScrollView { EmptyRepositoriesView().padding(.top, 80) }
                } else if let repo = selectedRepository(in: visible) {
                    RepositoryDetailView(repo: repo).id(repo.id)
                } else {
                    ContentUnavailableView("没有符合条件的仓库", systemImage: "line.3.horizontal.decrease.circle",
                                           description: Text("换个搜索词或筛选条件试试。"))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .navigationTitle("")
        }
        .searchable(text: $search, placement: .sidebar, prompt: Text("搜索仓库"))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                SyncAllMenu()

                Button {
                    openWindow(id: WindowID.logs)
                } label: {
                    Label("日志", systemImage: "list.bullet.rectangle")
                }
                .help("查看全部日志")

                SettingsLink {
                    Label("设置", systemImage: "gearshape")
                }
                .help("设置")
            }
        }
    }

    // MARK: Sidebar

    private func sidebar(_ visible: [RepositoryConfig]) -> some View {
        List(selection: selection) {
            Section {
                ForEach(visible) { repo in
                    RepositoryRow(repo: repo)
                        .tag(repo.id)
                        .contextMenu {
                            Button("立即同步") { model.sync(repo.id, trigger: .manualSingle) }
                            Button("在 Finder 中显示") { model.revealInFinder(repo.id) }
                        }
                }
                .onMove(perform: canReorder ? { model.moveRepositories(from: $0, to: $1) } : nil)
            } header: {
                HStack {
                    Text("仓库")
                    Spacer()
                    sortFilterMenu
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if visible.isEmpty, !model.repositories.isEmpty {
                Text("没有符合条件的仓库").font(.callout).foregroundStyle(.secondary)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SidebarFooter(reorderHint: reorderHint(visible))
        }
    }

    private var sortFilterMenu: some View {
        Menu {
            Picker("排序", selection: $sort) {
                ForEach(RepositorySort.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            Picker("显示", selection: $filter) {
                ForEach(RepositoryFilter.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: filter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("排序与筛选")
    }

    private func reorderHint(_ visible: [RepositoryConfig]) -> String? {
        guard !canReorder, visible.count > 1 else { return nil }
        return sort == .manual ? String(localized: "清除搜索和筛选后可以拖动排序") : String(localized: "选择「手动排序」后可以拖动排序")
    }

    // MARK: Data

    /// Dragging only makes sense when the list shows every repository in manual order.
    private var canReorder: Bool {
        sort == .manual && filter == .all && search.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var selection: Binding<UUID?> {
        Binding(get: { UUID(uuidString: selectionID) }, set: { selectionID = $0?.uuidString ?? "" })
    }

    private func selectedRepository(in visible: [RepositoryConfig]) -> RepositoryConfig? {
        visible.first { $0.id.uuidString == selectionID } ?? visible.first
    }

    private var visibleRepositories: [RepositoryConfig] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let filtered = model.repositories.filter { repo in
            if !query.isEmpty, !repo.displayName.localizedCaseInsensitiveContains(query),
               !repo.path.localizedCaseInsensitiveContains(query) { return false }
            switch filter {
            case .all: return true
            case .attention: return repo.lastStatus.isProblem
            case .autoSyncOn: return repo.autoSyncEnabled
            case .autoSyncOff: return !repo.autoSyncEnabled
            }
        }
        switch sort {
        case .manual:
            return filtered
        case .name:
            return filtered.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        case .lastSync:
            return filtered.sorted { ($0.lastSyncAt ?? .distantPast) > ($1.lastSyncAt ?? .distantPast) }
        case .problemsFirst:
            // A stable partition keeps the manual order within each group.
            return filtered.filter { $0.lastStatus.isProblem } + filtered.filter { !$0.lastStatus.isProblem }
        }
    }
}

/// One line per repository: status, name, and when it last synced (or what went wrong).
private struct RepositoryRow: View {
    @Environment(AppModel.self) private var model
    let repo: RepositoryConfig

    var body: some View {
        let status = model.displayStatus(for: repo)
        HStack(spacing: 8) {
            Group {
                if status.isActive {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: status.symbol).foregroundStyle(status.color)
                }
            }
            .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(repo.displayName).lineLimit(1)
                    .foregroundStyle(repo.autoSyncEnabled ? .primary : .secondary)
                Text(subtitle(status))
                    .font(.caption)
                    .foregroundStyle(status.isProblem ? status.color : .secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            // Auto sync at a glance, and one click to switch it.
            Button {
                model.setAutoSync(!repo.autoSyncEnabled, for: repo.id)
            } label: {
                Image(systemName: repo.autoSyncEnabled ? "arrow.triangle.2.circlepath" : "pause.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(repo.autoSyncEnabled ? Color.green : Color.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(repo.autoSyncEnabled ? String(localized: "自动同步中，点击暂停") : String(localized: "自动同步已暂停，点击开启"))
        }
        .padding(.vertical, 2)
    }

    private func subtitle(_ status: SyncStatus) -> String {
        if status.isActive { return model.runtime[repo.id]?.phase?.displayName ?? status.displayName }
        if status.isProblem { return repo.lastMessage ?? status.displayName }
        return repo.lastSyncAt.map { String(localized: "\($0.relativeDescription)同步") } ?? String(localized: "从未成功同步")
    }
}

/// Account and auto-sync status plus the Add button, pinned to the bottom of the sidebar.
private struct SidebarFooter: View {
    @Environment(AppModel.self) private var model
    let reorderHint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let reorderHint {
                Text(reorderHint).font(.caption2).foregroundStyle(.secondary)
            }
            Divider()
            AuthStatusLabel()
            IntervalStatusLine()
            // One full-width control: the main part adds a local folder, the arrow lists the other ways.
            HStack(spacing: 0) {
                Button {
                    RepositoryPicker.present(model: model)
                } label: {
                    Label("添加仓库", systemImage: "plus")
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("选择本地文件夹（也可以直接拖进窗口）")
                Divider().frame(height: 18)
                Menu {
                    Button {
                        RepositoryPicker.present(model: model)
                    } label: {
                        Label("添加本地文件夹…", systemImage: "folder.badge.plus")
                    }
                    Button {
                        model.activeSheet = .downloadFromGitHub
                    } label: {
                        Label(model.auth.state.isUsable ? String(localized: "从 GitHub 下载…") : String(localized: "从 GitHub 下载…（需要先登录）"),
                              systemImage: "icloud.and.arrow.down")
                    }
                    .disabled(!model.auth.state.isUsable)
                    Divider()
                    Button {
                        model.activeSheet = .downloadFromGitHub
                    } label: {
                        Label("管理 GitHub 上的仓库…", systemImage: "list.bullet.rectangle")
                    }
                    .disabled(!model.auth.state.isUsable)
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .frame(width: 34)
                .help("从 GitHub 下载或管理 GitHub 上的仓库")
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.07), in: Capsule())
            .frame(maxWidth: .infinity)
            .disabled(model.gitEnvironment == nil)
            .help("点击选择本地文件夹（也可以直接拖进窗口）；点箭头可从 GitHub 下载仓库")
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }
}

/// "Sync All" in the toolbar: click to sync every repository now; its menu holds the sync
/// interval and turning auto sync off or on for all repositories.
struct SyncAllMenu: View {
    @Environment(AppModel.self) private var model
    @State private var showCustom = false

    var body: some View {
        Menu {
            IntervalMenuItems(showCustom: $showCustom)
            Divider()
            if model.autoSyncCount > 0 {
                Button("全部暂停自动同步") { model.setAutoSyncForAll(false) }
            }
            if model.autoSyncCount < model.repositories.count {
                Button("全部开启自动同步") { model.setAutoSyncForAll(true) }
            }
        } label: {
            Label("全部同步", systemImage: "arrow.triangle.2.circlepath")
                .labelStyle(.titleAndIcon)
        } primaryAction: {
            model.syncAll(trigger: .manualAll)
        }
        // macOS keeps a toolbar menu's items once built; a new identity rebuilds them with the
        // current checkmark and pause/resume entries.
        .id("\(model.settings.intervalMinutes)-\(model.autoSyncCount)")
        .fixedSize()
        .disabled(model.repositories.isEmpty || model.gitEnvironment == nil)
        .help("点击马上同步所有仓库（包括自动同步关闭的）；点箭头设置同步间隔")
        .popover(isPresented: $showCustom) { CustomIntervalView(isPresented: $showCustom) }
    }
}

/// The auto-sync status at the bottom of the sidebar. Display only: the interval is changed from
/// the Sync All menu in the toolbar.
struct IntervalStatusLine: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let running = model.autoSyncCount > 0
        HStack(alignment: .center, spacing: 8) {
            // Same width as the account icon above, so both lines of text start together.
            Image(systemName: running ? "arrow.triangle.2.circlepath" : "pause.circle")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(running ? (model.isOnline ? Color.green : Color.gray) : Color.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.overallStatusText).foregroundStyle(.primary)
                Group {
                    if running, let next = model.nextSyncDate {
                        Text("每 \(IntervalMenuItems.label(model.settings.intervalMinutes)) · 下次 \(next.formatted(date: .omitted, time: .shortened))")
                    } else {
                        Text("每 \(IntervalMenuItems.label(model.settings.intervalMinutes))")
                    }
                }
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
    }
}

/// The interval choices in the toolbar's Sync All menu.
struct IntervalMenuItems: View {
    @Environment(AppModel.self) private var model
    @Binding var showCustom: Bool

    var body: some View {
        let current = model.settings.intervalMinutes
        Section("同步间隔") {
            ForEach(AppSettings.presetIntervals, id: \.self) { minutes in
                Toggle(Self.label(minutes), isOn: Binding(
                    get: { model.settings.intervalMinutes == minutes },
                    set: { _ in model.setInterval(minutes: minutes) }))
            }
            if !AppSettings.presetIntervals.contains(current) {
                Toggle(String(localized: "自定义：\(Self.label(current))"), isOn: .constant(true))
            }
            Button("自定义…") { showCustom = true }
        }
    }

    static func label(_ minutes: Int) -> String {
        minutes == 60 ? String(localized: "60 分钟（1 小时）") : String(localized: "\(minutes) 分钟")
    }
}

/// Lets the user type any interval.
struct CustomIntervalView: View {
    @Environment(AppModel.self) private var model
    @Binding var isPresented: Bool
    @State private var minutes = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("自定义同步间隔").font(.headline)
            Stepper(value: $minutes, in: 1...1440) {
                HStack {
                    TextField("分钟", value: $minutes, format: .number)
                        .frame(width: 70)
                        .textFieldStyle(.roundedBorder)
                    Text("分钟")
                }
            }
            HStack {
                Spacer()
                Button("取消") { isPresented = false }
                Button("应用") {
                    model.setInterval(minutes: minutes)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 260)
        .onAppear { minutes = model.settings.intervalMinutes }
    }
}

