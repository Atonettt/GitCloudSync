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
    case all, attention, syncing, autoSyncOff

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: String(localized: "全部")
        case .attention: String(localized: "需要处理")
        case .syncing: String(localized: "同步中")
        case .autoSyncOff: String(localized: "自动同步已关闭")
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
                Button {
                    model.syncAll(trigger: .manualAll)
                } label: {
                    Label("立即同步全部", systemImage: "arrow.triangle.2.circlepath")
                }
                .help("马上同步列表中的所有仓库，包括自动同步关闭的仓库")
                .disabled(model.repositories.isEmpty || model.gitEnvironment == nil)

                IntervalMenu()

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
            case .syncing: return model.runtime[repo.id]?.isSyncing == true
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
                Text(subtitle(status))
                    .font(.caption)
                    .foregroundStyle(status.isProblem ? status.color : .secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private func subtitle(_ status: SyncStatus) -> String {
        if status.isActive { return model.runtime[repo.id]?.phase?.displayName ?? status.displayName }
        if status.isProblem { return repo.lastMessage ?? status.displayName }
        let synced = repo.lastSyncAt.map { String(localized: "\($0.relativeDescription)同步") } ?? String(localized: "从未成功同步")
        return repo.autoSyncEnabled ? synced : synced + String(localized: " · 自动同步已关闭")
    }
}

/// Account and auto-sync status plus the Add button, pinned to the bottom of the sidebar.
private struct SidebarFooter: View {
    @Environment(AppModel.self) private var model
    let reorderHint: String?

    var body: some View {
        let running = model.autoSyncCount > 0
        VStack(alignment: .leading, spacing: 8) {
            if let reorderHint {
                Text(reorderHint).font(.caption2).foregroundStyle(.secondary)
            }
            Divider()
            AuthStatusLabel()
            HStack(spacing: 6) {
                Circle()
                    .fill(running ? (model.isOnline ? Color.green : Color.gray) : Color.secondary.opacity(0.5))
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.overallStatusText)
                    if running, let next = model.nextSyncDate {
                        Text("下次同步：\(next.formatted(date: .omitted, time: .shortened))").foregroundStyle(.secondary)
                    }
                }
            }
            .font(.caption)
            Button {
                RepositoryPicker.present(model: model)
            } label: {
                Label("添加仓库", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .disabled(model.gitEnvironment == nil)
            .help("选择文件夹，或直接把文件夹拖进窗口")
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }
}

/// The sync interval in the toolbar, with a custom value in a popover.
struct IntervalMenu: View {
    @Environment(AppModel.self) private var model
    @State private var customMinutes = 20
    @State private var showCustom = false

    var body: some View {
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
            Label("每 \(label(model.settings.intervalMinutes))", systemImage: "timer")
                .labelStyle(.titleAndIcon)
        }
        .fixedSize()
        .help("同步间隔")
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

    private func label(_ minutes: Int) -> String {
        minutes == 60 ? String(localized: "60 分钟（1 小时）") : String(localized: "\(minutes) 分钟")
    }
}
