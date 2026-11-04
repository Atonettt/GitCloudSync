import QuickLook
import SwiftUI

/// Version history in its own window, laid out like Mail: a list on the left, its items in the
/// middle, and a live preview of the selected file on the right.
struct HistoryView: View {
    @Environment(AppModel.self) private var model
    let repoID: UUID
    /// Opens the window on this file's versions (from the Files tab of the main window).
    let initialPath: String?

    init(request: HistoryRequest) {
        repoID = request.repoID
        initialPath = request.path
        _mode = State(initialValue: request.path == nil ? .timeline : .files)
    }

    enum Mode: String, CaseIterable, Identifiable {
        case timeline, files, deleted
        var id: String { rawValue }

        var title: String {
            switch self {
            case .timeline: String(localized: "按时间")
            case .files: String(localized: "按文件")
            case .deleted: String(localized: "最近删除")
            }
        }
    }

    @State private var mode: Mode
    @State private var search = ""
    @State private var previewTarget: PreviewTarget?
    @State private var quickLookURL: URL?
    @State private var errorText: String?
    @State private var fileRestore: FileRestoreRequest?

    var body: some View {
        let repo = model.repository(repoID)
        Group {
            if repo == nil {
                ContentUnavailableView("仓库已不在列表中", systemImage: "folder.badge.questionmark")
            } else {
                columns
            }
        }
        .frame(minWidth: 1060, minHeight: 600)
        .navigationTitle("\(repo?.displayName ?? "") · 版本历史")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
        .onChange(of: mode) {
            previewTarget = nil
            search = ""
        }
        .quickLookPreview($quickLookURL)
        .modifier(FileRestoreConfirmation(repoID: repoID, request: $fileRestore))
        .alert("操作失败", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("好") { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
    }

    @ViewBuilder
    private var columns: some View {
        let actions = PreviewActions(
            openInQuickLook: { quickLookURL = $0 },
            restore: { fileRestore = $0 },
            fail: { errorText = $0 }
        )
        switch mode {
        case .timeline:
            TimelineColumns(repoID: repoID, search: $search, preview: $previewTarget, actions: actions)
        case .files:
            FilesColumns(repoID: repoID, initialFile: initialPath, search: $search, preview: $previewTarget, actions: actions)
        case .deleted:
            DeletedColumns(repoID: repoID, search: $search, preview: $previewTarget, actions: actions)
        }
    }
}

// MARK: - Shared pieces

/// What a version-history window shows: a repository, optionally starting on one file.
struct HistoryRequest: Codable, Hashable {
    var repoID: UUID
    var path: String?
}

/// One file in one version, ready to preview, save or restore.
struct PreviewTarget: Hashable, Identifiable {
    /// The file's path inside `commit`.
    var path: String
    var commit: String
    var date: Date
    var subtitle: String
    /// Where a restore writes the file (today's name).
    var restorePath: String
    var restoreTitle: String
    var restoreDisabledReason: String?

    var id: String { commit + "\u{0}" + path }
}

/// Callbacks from the columns back to the window.
struct PreviewActions {
    let openInQuickLook: (URL) -> Void
    let restore: (FileRestoreRequest) -> Void
    let fail: (String) -> Void
}

private enum HistoryFormat {
    static func date(_ date: Date) -> String {
        date.formatted(.dateTime.year().month().day().hour().minute())
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// "今天 15:40", "昨天 18:00", "11月1日 09:12".
    static func relative(_ date: Date) -> String {
        "\(day(date)) \(time(date))"
    }

    static func day(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return String(localized: "今天") }
        if calendar.isDateInYesterday(date) { return String(localized: "昨天") }
        if calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
            return date.formatted(.dateTime.month().day())
        }
        return date.formatted(.dateTime.year().month().day())
    }

    static func size(_ bytes: Int64?) -> String {
        bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""
    }

    static func fileName(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    static func folder(_ path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    static func describe(_ error: Error) -> String {
        (error as? SyncFailure)?.fullReport ?? error.localizedDescription
    }

    static func symbol(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "doc", "docx", "pages", "txt", "md", "rtf": "doc.text"
        case "xls", "xlsx", "numbers", "csv": "tablecells"
        case "ppt", "pptx", "key": "rectangle.on.rectangle"
        case "pdf": "doc.richtext"
        case "png", "jpg", "jpeg", "heic", "gif", "tif", "tiff", "svg": "photo"
        case "mov", "mp4", "m4v": "film"
        case "zip", "rar", "7z": "doc.zipper"
        default: "doc"
        }
    }
}

private enum RestoreBlockedReason {
    @MainActor
    static func text(model: AppModel, repoID: UUID) -> String? {
        if model.runtime[repoID]?.isSyncing == true { return String(localized: "正在同步，请稍候") }
        if model.repository(repoID)?.pausedForConflict == true { return String(localized: "请先解决冲突") }
        return nil
    }
}

private extension View {
    /// Re-runs `reload` when a sync or restore of this repository finishes.
    func reloadAfterSync(_ syncing: Bool, _ reload: @escaping () async -> Void) -> some View {
        onChange(of: syncing) { _, now in
            if !now { Task { await reload() } }
        }
    }
}

/// A file name with its folder below, used in every list.
private struct FileLabel: View {
    let path: String
    var detail: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: HistoryFormat.symbol(for: path)).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(HistoryFormat.fileName(path)).lineLimit(1).truncationMode(.middle)
                let text = detail ?? HistoryFormat.folder(path)
                if !text.isEmpty {
                    Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// The three columns used by every mode.
private struct HistoryColumns<Sidebar: View, Content: View>: View {
    @Binding var search: String
    let searchPrompt: String
    let preview: PreviewTarget?
    let repoID: UUID
    let actions: PreviewActions
    @ViewBuilder let sidebar: Sidebar
    @ViewBuilder let content: Content

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        } content: {
            content
                .navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 400)
        } detail: {
            FilePreviewPane(repoID: repoID, target: preview, actions: actions)
        }
        .searchable(text: $search, placement: .sidebar, prompt: Text(searchPrompt))
    }
}

// MARK: - Preview

/// Shows the selected version of a file inline (any type Quick Look understands), with
/// actions to open it full size, save a copy, or restore it.
private struct FilePreviewPane: View {
    @Environment(AppModel.self) private var model
    let repoID: UUID
    let target: PreviewTarget?
    let actions: PreviewActions

    @State private var url: URL?
    @State private var loading = false
    @State private var failure: String?

    var body: some View {
        Group {
            if let target {
                VStack(spacing: 0) {
                    header(target)
                    Divider()
                    ZStack {
                        if let url {
                            QuickLookView(url: url)
                        } else if loading {
                            ProgressView()
                        } else if let failure {
                            ContentUnavailableView("无法预览", systemImage: "eye.slash", description: Text(failure))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ContentUnavailableView("选择一个文件", systemImage: "doc.text.magnifyingglass",
                                       description: Text("选中的文件会在这里预览。"))
            }
        }
        .task(id: target?.id) { await load(target) }
    }

    private func header(_ target: PreviewTarget) -> some View {
        HStack(spacing: 12) {
            Image(systemName: HistoryFormat.symbol(for: target.path)).font(.title2).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(HistoryFormat.fileName(target.path)).font(.headline).lineLimit(1).truncationMode(.middle)
                Text(target.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button {
                if let url { actions.openInQuickLook(url) }
            } label: {
                Label("快速查看", systemImage: "eye").labelStyle(.iconOnly)
            }
            .disabled(url == nil)
            .help("用快速查看全屏打开这个版本")
            Button {
                Task {
                    await model.saveVersionCopy(repoID, path: target.path, commit: target.commit, date: target.date,
                                                besides: target.restorePath)
                }
            } label: {
                Label("另存副本", systemImage: "plus.square.on.square").labelStyle(.iconOnly)
            }
            .help("另存为「文件名 (日期 版本)」，当前文件不变")
            Button(target.restoreTitle) {
                actions.restore(FileRestoreRequest(path: target.restorePath, sourcePath: target.path,
                                                   commit: target.commit, date: target.date))
            }
            .buttonStyle(.borderedProminent)
            .disabled(target.restoreDisabledReason != nil)
            .help(target.restoreDisabledReason ?? String(localized: "把这个文件恢复为这个版本"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func load(_ target: PreviewTarget?) async {
        url = nil
        failure = nil
        guard let target, let browser = model.historyBrowser(repoID) else { return }
        loading = true
        defer { loading = false }
        do {
            url = try await browser.exportForPreview(path: target.path, commit: target.commit, date: target.date)
        } catch {
            failure = HistoryFormat.describe(error)
        }
    }
}

/// Pending single-file restore, confirmed in a dialog.
struct FileRestoreRequest: Identifiable {
    let path: String
    let sourcePath: String
    let commit: String
    let date: Date
    var id: String { commit + path }
}

private struct FileRestoreConfirmation: ViewModifier {
    @Environment(AppModel.self) private var model
    let repoID: UUID
    @Binding var request: FileRestoreRequest?

    func body(content: Content) -> some View {
        content.confirmationDialog(title, isPresented: Binding(get: { request != nil }, set: { if !$0 { request = nil } })) {
            if let request {
                Button("恢复为这个版本") {
                    model.restore(repoID, target: .file(path: request.path, sourcePath: request.sourcePath, commit: request.commit),
                                  description: String(localized: "「\(HistoryFormat.fileName(request.path))」到 \(HistoryFormat.date(request.date)) 的版本"))
                }
                Button("改为另存副本") {
                    Task {
                        await model.saveVersionCopy(repoID, path: request.sourcePath, commit: request.commit,
                                                    date: request.date, besides: request.path)
                    }
                }
            }
        } message: {
            Text("当前版本不会丢失：恢复前会先保存未同步的修改并创建备份，恢复本身作为一次新的同步上传，以后也可以再恢复回来。另一台 Mac 会在下次同步时收到这个版本。")
        }
    }

    private var title: String {
        guard let request else { return "" }
        return String(localized: "将「\(HistoryFormat.fileName(request.path))」恢复到 \(HistoryFormat.relative(request.date)) 的版本？")
    }
}

/// Status of the repository while the history window is open.
private struct HistoryStatusLine: View {
    @Environment(AppModel.self) private var model
    let repoID: UUID

    var body: some View {
        let repo = model.repository(repoID)
        let runtime = model.runtime[repoID]
        if runtime?.isSyncing == true {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(runtime?.phase?.displayName ?? String(localized: "正在同步…"))
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(10)
        } else if repo?.pausedForConflict == true {
            Label("此仓库存在冲突，请先在主窗口解决冲突再恢复版本", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
                .padding(10)
        }
    }
}

// MARK: - By time

private struct TimelineColumns: View {
    @Environment(AppModel.self) private var model
    let repoID: UUID
    @Binding var search: String
    @Binding var preview: PreviewTarget?
    let actions: PreviewActions

    enum Scope: String, CaseIterable, Identifiable {
        case changes, all
        var id: String { rawValue }
    }

    private static let pageSize = 150

    @State private var commits: [HistoryCommit] = []
    @State private var selectedCommit: String?
    @State private var loading = true
    @State private var canLoadMore = false
    @State private var scope: Scope = .changes
    @State private var allFiles: [String] = []
    @State private var fileFilter = ""
    @State private var selectedPath: String?
    @State private var repositoryRestore: PendingRepositoryRestore?
    @State private var alreadyCurrent = false

    struct PendingRepositoryRestore: Identifiable {
        let commit: HistoryCommit
        let preview: RestorePreview
        var id: String { commit.id }
    }

    var body: some View {
        let syncing = model.runtime[repoID]?.isSyncing == true
        HistoryColumns(search: $search, searchPrompt: String(localized: "搜索版本"), preview: preview,
                       repoID: repoID, actions: actions) {
            List(selection: $selectedCommit) {
                ForEach(days, id: \.day) { group in
                    Section(HistoryFormat.day(group.day)) {
                        ForEach(group.commits) { commit in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(HistoryFormat.time(commit.date)).font(.body.weight(.semibold).monospacedDigit())
                                Text(commit.id == commits.first?.id ? String(localized: "当前版本") : "\(commit.title) · \(commit.source)")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .padding(.vertical, 2)
                            .tag(commit.id)
                        }
                    }
                }
                if canLoadMore, search.isEmpty {
                    Button("加载更早的记录") { Task { await load(more: true) } }
                        .buttonStyle(.link)
                }
            }
            .listStyle(.sidebar)
            .overlay { if loading && commits.isEmpty { ProgressView() } }
        } content: {
            if let commit = commits.first(where: { $0.id == selectedCommit }) {
                commitContent(commit)
            } else {
                ContentUnavailableView("选择一个版本", systemImage: "clock",
                                       description: Text("左侧按时间列出每次同步保存的版本。"))
            }
        }
        .task { await load(more: false) }
        .reloadAfterSync(syncing) { await load(more: false) }
        .onChange(of: selectedCommit) {
            selectedPath = nil
            allFiles = []
            fileFilter = ""
            Task { await loadAllFilesIfNeeded() }
        }
        .onChange(of: scope) {
            selectedPath = nil
            Task { await loadAllFilesIfNeeded() }
        }
        .onChange(of: selectedPath) { updatePreview() }
        .sheet(item: $repositoryRestore) { item in
            RepositoryRestoreConfirmView(commit: item.commit, preview: item.preview) {
                model.restore(repoID, target: .repository(commit: item.commit.id),
                              description: String(localized: "整个仓库到 \(HistoryFormat.date(item.commit.date)) 的状态"))
            }
        }
        .alert("已经是这个版本的状态", isPresented: $alreadyCurrent) {
            Button("好") {}
        } message: {
            Text("最新同步的内容与所选版本完全相同，无需恢复。")
        }
    }

    private var days: [(day: Date, commits: [HistoryCommit])] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let calendar = Calendar.current
        var result: [(day: Date, commits: [HistoryCommit])] = []
        for commit in commits {
            if !query.isEmpty, !commit.title.localizedCaseInsensitiveContains(query),
               !commit.source.localizedCaseInsensitiveContains(query),
               !commit.changes.contains(where: { $0.path.localizedCaseInsensitiveContains(query) }) { continue }
            let day = calendar.startOfDay(for: commit.date)
            if result.last?.day == day {
                result[result.count - 1].commits.append(commit)
            } else {
                result.append((day, [commit]))
            }
        }
        return result
    }

    private func commitContent(_ commit: HistoryCommit) -> some View {
        let isCurrent = commit.id == commits.first?.id
        let blocked = RestoreBlockedReason.text(model: model, repoID: repoID)
        return VStack(alignment: .leading, spacing: 0) {
            commitHeader(commit, isCurrent: isCurrent)
                .padding(14)
            fileList(commit)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HistoryStatusLine(repoID: repoID)
                Divider()
                Button {
                    Task { await prepareRepositoryRestore(commit) }
                } label: {
                    Label("恢复整个仓库到这个版本…", systemImage: "clock.arrow.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .disabled(isCurrent || blocked != nil)
                .help(isCurrent ? String(localized: "这是最新同步的版本。") : (blocked ?? String(localized: "整个文件夹回到这个版本：先列出会改动的文件，确认后才恢复。")))
                .padding([.horizontal, .bottom], 12)
            }
        }
    }

    private func commitHeader(_ commit: HistoryCommit, isCurrent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(HistoryFormat.relative(commit.date)).font(.title3.bold())
                    if isCurrent {
                        Text("当前版本").font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.green.opacity(0.18), in: Capsule())
                    }
                }
                Text("\(commit.title) · \(commit.source)").font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Picker("", selection: $scope) {
                Text("改动的文件（\(commit.changes.count)）").tag(Scope.changes)
                Text("全部文件").tag(Scope.all)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if scope == .all {
                TextField("筛选文件", text: $fileFilter).textFieldStyle(.roundedBorder)
            }
        }
    }

    @ViewBuilder
    private func fileList(_ commit: HistoryCommit) -> some View {
        switch scope {
        case .changes:
            List(commit.changes, id: \.path, selection: $selectedPath) { change in
                var detail = change.displayStatus
                if let old = change.oldPath { detail += String(localized: " · 原名「\(HistoryFormat.fileName(old))」") }
                return FileLabel(path: change.path, detail: detail).tag(change.path)
            }
            .overlay { if commit.changes.isEmpty { Text("这个版本没有文件变化").foregroundStyle(.secondary) } }
        case .all:
            let query = fileFilter.trimmingCharacters(in: .whitespaces)
            let files = query.isEmpty ? allFiles : allFiles.filter { $0.localizedCaseInsensitiveContains(query) }
            List(files, id: \.self, selection: $selectedPath) { path in
                FileLabel(path: path).tag(path)
            }
            .overlay { if allFiles.isEmpty { ProgressView() } }
        }
    }

    private func updatePreview() {
        guard let path = selectedPath, let commit = commits.first(where: { $0.id == selectedCommit }) else {
            preview = nil
            return
        }
        let isCurrent = commit.id == commits.first?.id
        let blocked = RestoreBlockedReason.text(model: model, repoID: repoID)
        let change = scope == .changes ? commit.changes.first { $0.path == path } : nil
        // A file deleted in this version is shown and restored as it was just before.
        let deleted = change?.status == "D"
        guard let source = deleted ? commit.parents.first : commit.id else {
            preview = nil
            return
        }
        preview = PreviewTarget(
            path: path,
            commit: source,
            date: commit.date,
            subtitle: "\(HistoryFormat.relative(commit.date)) · \(commit.source)" + (change.map { " · \($0.displayStatus)" } ?? ""),
            restorePath: path,
            restoreTitle: deleted ? String(localized: "找回…") : String(localized: "恢复…"),
            restoreDisabledReason: blocked ?? (isCurrent && !deleted ? String(localized: "这就是最新同步的内容") : nil)
        )
    }

    private func loadAllFilesIfNeeded() async {
        guard scope == .all, allFiles.isEmpty, let commit = selectedCommit,
              let browser = model.historyBrowser(repoID) else { return }
        do {
            let files = try await browser.trackedFiles(at: commit)
            if selectedCommit == commit { allFiles = files }
        } catch {
            actions.fail(HistoryFormat.describe(error))
        }
    }

    private func load(more: Bool) async {
        guard let browser = model.historyBrowser(repoID) else { return }
        loading = true
        defer { loading = false }
        do {
            let page = try await browser.timeline(limit: Self.pageSize, skip: more ? commits.count : 0)
            commits = more ? commits + page : page
            canLoadMore = page.count == Self.pageSize
            if selectedCommit == nil || !commits.contains(where: { $0.id == selectedCommit }) {
                selectedCommit = commits.first?.id
            }
        } catch {
            actions.fail(HistoryFormat.describe(error))
        }
    }

    private func prepareRepositoryRestore(_ commit: HistoryCommit) async {
        guard let browser = model.historyBrowser(repoID) else { return }
        do {
            let preview = try await browser.previewRestore(to: commit.id)
            if preview.isEmpty {
                alreadyCurrent = true
            } else {
                repositoryRestore = PendingRepositoryRestore(commit: commit, preview: preview)
            }
        } catch {
            actions.fail(HistoryFormat.describe(error))
        }
    }
}

// MARK: - By file

private struct FilesColumns: View {
    @Environment(AppModel.self) private var model
    let repoID: UUID
    let initialFile: String?
    @Binding var search: String
    @Binding var preview: PreviewTarget?
    let actions: PreviewActions

    @State private var files: [String] = []
    @State private var selectedFile: String?
    @State private var versions: [FileVersion] = []
    @State private var selectedVersion: String?
    @State private var loadingFiles = true
    @State private var loadingVersions = false

    var body: some View {
        let syncing = model.runtime[repoID]?.isSyncing == true
        HistoryColumns(search: $search, searchPrompt: String(localized: "搜索文件"), preview: preview,
                       repoID: repoID, actions: actions) {
            List(filteredFiles, id: \.self, selection: $selectedFile) { path in
                FileLabel(path: path).tag(path)
            }
            .listStyle(.sidebar)
            .overlay {
                if loadingFiles { ProgressView() }
                else if files.isEmpty { Text("没有已同步的文件").foregroundStyle(.secondary) }
            }
        } content: {
            if let selectedFile {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(HistoryFormat.fileName(selectedFile)).font(.title3.bold()).lineLimit(1).truncationMode(.middle)
                        Text("\(versions.filter { !$0.isDeletion }.count) 个版本 · \(selectedFile)")
                            .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    .padding(14)
                    List(selection: $selectedVersion) {
                        ForEach(Array(versions.enumerated()), id: \.element.id) { index, version in
                            versionRow(version, isLatest: index == 0)
                        }
                    }
                    .overlay {
                        if loadingVersions { ProgressView() }
                        else if versions.isEmpty { Text("没有找到历史版本").foregroundStyle(.secondary) }
                    }
                    HistoryStatusLine(repoID: repoID)
                }
            } else {
                ContentUnavailableView("选择一个文件", systemImage: "doc.text.magnifyingglass",
                                       description: Text("左侧列出最近一次同步时仓库中的所有文件。"))
            }
        }
        .task { await loadFiles() }
        .onChange(of: selectedFile) { Task { await loadVersions() } }
        .onChange(of: selectedVersion) { updatePreview() }
        .reloadAfterSync(syncing) {
            await loadFiles()
            await loadVersions()
        }
    }

    private var filteredFiles: [String] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return files }
        return files.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    @ViewBuilder
    private func versionRow(_ version: FileVersion, isLatest: Bool) -> some View {
        if version.isDeletion {
            Label("\(HistoryFormat.relative(version.commit.date)) 被删除，后来又重新添加", systemImage: "trash")
                .font(.callout).foregroundStyle(.secondary)
                .selectionDisabled()
        } else {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(HistoryFormat.relative(version.commit.date)).font(.body.weight(.medium))
                    if isLatest {
                        Text("最新同步版本").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.green.opacity(0.18), in: Capsule())
                    }
                }
                Text(subtitle(version)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.vertical, 2)
            .tag(version.id)
        }
    }

    private func subtitle(_ version: FileVersion) -> String {
        var parts = [version.commit.source, HistoryFormat.size(version.size)]
        if let selectedFile, version.path != selectedFile {
            parts.append(String(localized: "当时名为「\(HistoryFormat.fileName(version.path))」"))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func updatePreview() {
        guard let selectedFile, let index = versions.firstIndex(where: { $0.id == selectedVersion }) else {
            preview = nil
            return
        }
        let version = versions[index]
        let blocked = RestoreBlockedReason.text(model: model, repoID: repoID)
        preview = PreviewTarget(
            path: version.path,
            commit: version.commit.id,
            date: version.commit.date,
            subtitle: "\(HistoryFormat.relative(version.commit.date)) · \(version.commit.source)",
            restorePath: selectedFile,
            restoreTitle: String(localized: "恢复…"),
            restoreDisabledReason: index == 0 ? String(localized: "这就是最新同步的版本") : blocked
        )
    }

    private func loadFiles() async {
        guard let browser = model.historyBrowser(repoID) else { return }
        do {
            files = try await browser.trackedFiles()
            if selectedFile == nil, let initialFile, files.contains(initialFile) { selectedFile = initialFile }
        } catch {
            actions.fail(HistoryFormat.describe(error))
        }
        loadingFiles = false
    }

    private func loadVersions() async {
        selectedVersion = nil
        guard let path = selectedFile, let browser = model.historyBrowser(repoID) else {
            versions = []
            return
        }
        loadingVersions = true
        defer { loadingVersions = false }
        do {
            let loaded = try await browser.versions(of: path)
            guard selectedFile == path else { return }
            versions = loaded
            selectedVersion = loaded.first { !$0.isDeletion }?.id
        } catch {
            actions.fail(HistoryFormat.describe(error))
        }
    }
}

// MARK: - Recently deleted

private struct DeletedColumns: View {
    @Environment(AppModel.self) private var model
    let repoID: UUID
    @Binding var search: String
    @Binding var preview: PreviewTarget?
    let actions: PreviewActions

    @State private var files: [DeletedFile] = []
    @State private var selection: String?
    @State private var loading = true

    var body: some View {
        let syncing = model.runtime[repoID]?.isSyncing == true
        HistoryColumns(search: $search, searchPrompt: String(localized: "搜索文件"), preview: preview,
                       repoID: repoID, actions: actions) {
            List(filtered, selection: $selection) { file in
                FileLabel(path: file.path, detail: String(localized: "\(HistoryFormat.relative(file.deletedIn.date)) 删除")).tag(file.id)
            }
            .listStyle(.sidebar)
            .overlay {
                if loading { ProgressView() }
                else if files.isEmpty { Text("没有已删除的文件").foregroundStyle(.secondary) }
            }
        } content: {
            if let file = files.first(where: { $0.id == selection }) {
                info(file)
            } else {
                ContentUnavailableView("选择一个已删除的文件", systemImage: "trash",
                                       description: Text("同步过、后来又被删除的文件会出现在左侧，可以预览或找回。"))
            }
        }
        .task { await load() }
        .reloadAfterSync(syncing) { await load() }
        .onChange(of: selection) { updatePreview() }
    }

    private var filtered: [DeletedFile] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return files }
        return files.filter { $0.path.localizedCaseInsensitiveContains(query) }
    }

    private func info(_ file: DeletedFile) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(HistoryFormat.fileName(file.path)).font(.title3.bold()).lineLimit(2)
                Text(file.path).font(.callout).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow { Text("删除时间").foregroundStyle(.secondary); Text(HistoryFormat.date(file.deletedIn.date)) }
                GridRow { Text("删除者").foregroundStyle(.secondary); Text(file.deletedIn.source) }
                GridRow { Text("大小").foregroundStyle(.secondary); Text(HistoryFormat.size(file.size).isEmpty ? "—" : HistoryFormat.size(file.size)) }
            }
            .font(.callout)
            Text("右侧预览的是删除前的最后一个版本。找回后它会回到原来的位置，并作为一次新的同步上传。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            HistoryStatusLine(repoID: repoID)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func updatePreview() {
        guard let file = files.first(where: { $0.id == selection }) else {
            preview = nil
            return
        }
        preview = PreviewTarget(
            path: file.path,
            commit: file.lastVersionCommit,
            date: file.deletedIn.date,
            subtitle: String(localized: "\(HistoryFormat.relative(file.deletedIn.date)) 由 \(file.deletedIn.source) 删除"),
            restorePath: file.path,
            restoreTitle: String(localized: "找回…"),
            restoreDisabledReason: RestoreBlockedReason.text(model: model, repoID: repoID)
        )
    }

    private func load() async {
        guard let browser = model.historyBrowser(repoID) else { return }
        do {
            files = try await browser.deletedFiles()
            if selection == nil || !files.contains(where: { $0.id == selection }) { selection = files.first?.id }
            updatePreview()
        } catch {
            actions.fail(HistoryFormat.describe(error))
        }
        loading = false
    }
}

/// Lists every file a whole-repository restore would touch before anything happens.
private struct RepositoryRestoreConfirmView: View {
    @Environment(\.dismiss) private var dismiss
    let commit: HistoryCommit
    let preview: RestorePreview
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("将整个仓库恢复到 \(HistoryFormat.date(commit.date))？").font(.title3.bold())
            Text("共 \(preview.total) 个文件会改变。未同步的本地修改会先保存进历史，并创建备份；恢复作为一次新的同步上传，之后仍可在历史中回到现在的状态。")
                .font(.callout).foregroundStyle(.secondary)
            List {
                section(String(localized: "改回旧内容"), preview.modified, symbol: "pencil", color: .accentColor)
                section(String(localized: "找回（之后被删除的文件）"), preview.restored, symbol: "plus.circle", color: .green)
                section(String(localized: "移除（之后新建的文件，仍保留在历史中）"), preview.removed, symbol: "minus.circle", color: .orange)
            }
            .frame(minHeight: 260)
            Text("未被同步的文件（例如被忽略规则排除或超过大小上限的文件）不受影响。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("恢复") {
                    onConfirm()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 600, height: 480)
    }

    @ViewBuilder
    private func section(_ title: String, _ paths: [String], symbol: String, color: Color) -> some View {
        if !paths.isEmpty {
            Section("\(title) · \(paths.count)") {
                ForEach(paths.prefix(300), id: \.self) { path in
                    Label(path, systemImage: symbol).foregroundStyle(color).lineLimit(1).truncationMode(.middle)
                }
                if paths.count > 300 {
                    Text("……以及另外 \(paths.count - 300) 个").foregroundStyle(.secondary)
                }
            }
        }
    }
}
