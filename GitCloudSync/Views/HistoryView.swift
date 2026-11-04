import QuickLook
import SwiftUI

/// Version history in its own window: a list on the left, details of the selection on the right.
struct HistoryView: View {
    @Environment(AppModel.self) private var model
    let repoID: UUID

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

    @State private var mode: Mode = .timeline
    @State private var previewURL: URL?
    @State private var errorText: String?

    var body: some View {
        let repo = model.repository(repoID)
        VStack(alignment: .leading, spacing: 14) {
            header(repo)
            if repo == nil {
                ContentUnavailableView("仓库已不在列表中", systemImage: "folder.badge.questionmark")
            } else {
                Group {
                    switch mode {
                    case .timeline: TimelineSplit(repoID: repoID, previewURL: $previewURL, errorText: $errorText)
                    case .files: FilesSplit(repoID: repoID, previewURL: $previewURL, errorText: $errorText)
                    case .deleted: DeletedSplit(repoID: repoID, previewURL: $previewURL, errorText: $errorText)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                statusLine
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 34)   // the title bar is hidden
        .padding(.bottom, 16)
        .frame(minWidth: 860, minHeight: 540)
        .background(GlassBackdrop())
        .navigationTitle("\(repo?.displayName ?? "") · 版本历史")
        .quickLookPreview($previewURL)
        .alert("操作失败", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("好") { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
    }

    private func header(_ repo: RepositoryConfig?) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "clock.arrow.circlepath").font(.title2).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(repo?.displayName ?? "") · 版本历史").font(.title2.bold())
                Text("每次同步保存一个版本，只能恢复到同步时的状态；两次同步之间的中间修改无法找回。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        let repo = model.repository(repoID)
        let runtime = model.runtime[repoID]
        if runtime?.isSyncing == true {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(runtime?.phase?.displayName ?? String(localized: "正在同步…")).font(.callout).foregroundStyle(.secondary)
            }
        } else if repo?.pausedForConflict == true {
            Label("此仓库存在冲突，请先在主窗口解决冲突再恢复版本", systemImage: "exclamationmark.triangle.fill")
                .font(.callout).foregroundStyle(.orange)
        } else if let message = repo?.lastMessage, repo?.lastStatus.isProblem == true {
            Label(message, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange)
        }
    }
}

// MARK: - Shared pieces

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

/// The two-column frame shared by every mode.
private struct SplitLayout<Sidebar: View, Detail: View>: View {
    let sidebarTitle: String
    @ViewBuilder let sidebar: Sidebar
    @ViewBuilder let detail: Detail

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text(sidebarTitle).font(.headline).padding(.horizontal, 14).padding(.top, 12)
                sidebar
            }
            .frame(width: 300)
            .frame(maxHeight: .infinity, alignment: .top)
            .glassPanel()

            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .glassPanel()
        }
    }
}

/// One file row with preview / save-copy / restore actions.
private struct FileActionRow: View {
    let path: String
    let subtitle: String
    var badge: String?
    var canOpen = true
    var restoreTitle = String(localized: "恢复…")
    var restoreDisabledReason: String?
    let onPreview: () -> Void
    let onSaveCopy: () -> Void
    let onRestore: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: HistoryFormat.symbol(for: path)).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(HistoryFormat.fileName(path)).lineLimit(1).truncationMode(.middle)
                    if let badge {
                        Text(badge).font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                }
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if canOpen {
                Button(action: onPreview) { Image(systemName: "eye") }
                    .help("用快速查看预览这个版本")
                Button(action: onSaveCopy) { Image(systemName: "plus.square.on.square") }
                    .help("另存为「文件名 (日期 版本)」，当前文件不变")
                Button(restoreTitle, action: onRestore)
                    .disabled(restoreDisabledReason != nil)
                    .help(restoreDisabledReason ?? String(localized: "把这个文件恢复为这个版本"))
            }
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 3)
    }
}

/// Pending single-file restore, confirmed in a dialog.
private struct FileRestoreRequest: Identifiable {
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

// MARK: - By time

private struct TimelineSplit: View {
    @Environment(AppModel.self) private var model
    let repoID: UUID
    @Binding var previewURL: URL?
    @Binding var errorText: String?

    private static let pageSize = 150

    @State private var commits: [HistoryCommit] = []
    @State private var selection: String?
    @State private var loading = true
    @State private var canLoadMore = false
    @State private var fileRestore: FileRestoreRequest?
    @State private var repositoryRestore: PendingRepositoryRestore?
    @State private var alreadyCurrent = false

    struct PendingRepositoryRestore: Identifiable {
        let commit: HistoryCommit
        let preview: RestorePreview
        var id: String { commit.id }
    }

    var body: some View {
        let syncing = model.runtime[repoID]?.isSyncing == true
        SplitLayout(sidebarTitle: String(localized: "历史版本")) {
            List(selection: $selection) {
                ForEach(days, id: \.day) { group in
                    Section(HistoryFormat.day(group.day)) {
                        ForEach(group.commits) { commit in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(HistoryFormat.time(commit.date)).font(.body.weight(.semibold).monospacedDigit())
                                Text(commit.id == commits.first?.id ? "当前版本" : "\(commit.title) · \(commit.source)")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .padding(.vertical, 3)
                            .tag(commit.id)
                        }
                    }
                }
                if canLoadMore {
                    Button("加载更早的记录") { Task { await load(more: true) } }
                        .buttonStyle(.borderless)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .overlay { if loading && commits.isEmpty { ProgressView() } }
        } detail: {
            if let commit = commits.first(where: { $0.id == selection }) {
                detail(commit)
            } else {
                ContentUnavailableView("选择一个版本", systemImage: "clock",
                                       description: Text("左侧按时间列出每次同步保存的版本。"))
            }
        }
        .task { await load(more: false) }
        .reloadAfterSync(syncing) { await load(more: false) }
        .modifier(FileRestoreConfirmation(repoID: repoID, request: $fileRestore))
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
        let calendar = Calendar.current
        var result: [(day: Date, commits: [HistoryCommit])] = []
        for commit in commits {
            let day = calendar.startOfDay(for: commit.date)
            if result.last?.day == day {
                result[result.count - 1].commits.append(commit)
            } else {
                result.append((day, [commit]))
            }
        }
        return result
    }

    @ViewBuilder
    private func detail(_ commit: HistoryCommit) -> some View {
        let isCurrent = commit.id == commits.first?.id
        let blocked = RestoreBlockedReason.text(model: model, repoID: repoID)
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(HistoryFormat.relative(commit.date)).font(.title3.bold())
                    if isCurrent {
                        Text("当前版本").font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.green.opacity(0.18), in: Capsule())
                    }
                }
                Text("\(commit.title) · \(commit.source) · \(commit.changes.count) 个文件变化")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding([.horizontal, .top], 16)

            Text("版本详情").font(.headline).padding(.horizontal, 16)
            List {
                ForEach(Array(commit.changes.enumerated()), id: \.offset) { _, change in
                    changeRow(change, commit: commit, isCurrent: isCurrent, blocked: blocked)
                }
            }
            .scrollContentBackground(.hidden)
            .overlay {
                if commit.changes.isEmpty { Text("这个版本没有文件变化").foregroundStyle(.secondary) }
            }

            Divider().padding(.horizontal, 16)
            HStack {
                Text(isCurrent ? String(localized: "这是最新同步的版本。") : String(localized: "整个文件夹回到这个版本：先列出会改动的文件，确认后才恢复。"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await prepareRepositoryRestore(commit) }
                } label: {
                    Label("恢复整个仓库到这个版本…", systemImage: "clock.arrow.circlepath")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isCurrent || blocked != nil)
                .help(blocked ?? "")
            }
            .padding([.horizontal, .bottom], 16)
        }
    }

    private func changeRow(_ change: HistoryChange, commit: HistoryCommit, isCurrent: Bool, blocked: String?) -> some View {
        // A file deleted in this version is restored from the version just before it.
        let deleted = change.status == "D"
        let source = deleted ? commit.parents.first : commit.id
        var subtitle = change.displayStatus
        if let old = change.oldPath { subtitle += String(localized: " · 原名「\(HistoryFormat.fileName(old))」") }
        let folder = HistoryFormat.folder(change.path)
        if !folder.isEmpty { subtitle += " · \(folder)" }
        return FileActionRow(
            path: change.path,
            subtitle: subtitle,
            canOpen: source != nil,
            restoreTitle: deleted ? String(localized: "找回…") : String(localized: "恢复…"),
            restoreDisabledReason: blocked ?? (isCurrent && !deleted ? String(localized: "这就是最新同步的内容") : nil),
            onPreview: { preview(change.path, commit: source ?? commit.id, date: commit.date) },
            onSaveCopy: {
                Task { await model.saveVersionCopy(repoID, path: change.path, commit: source ?? commit.id, date: commit.date) }
            },
            onRestore: {
                if let source {
                    fileRestore = FileRestoreRequest(path: change.path, sourcePath: change.path, commit: source, date: commit.date)
                }
            }
        )
    }

    private func preview(_ path: String, commit: String, date: Date) {
        guard let browser = model.historyBrowser(repoID) else { return }
        Task {
            do {
                previewURL = try await browser.exportForPreview(path: path, commit: commit, date: date)
            } catch {
                errorText = HistoryFormat.describe(error)
            }
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
            if selection == nil || !commits.contains(where: { $0.id == selection }) {
                selection = commits.first?.id
            }
        } catch {
            errorText = HistoryFormat.describe(error)
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
            errorText = HistoryFormat.describe(error)
        }
    }
}

// MARK: - By file

private struct FilesSplit: View {
    @Environment(AppModel.self) private var model
    let repoID: UUID
    @Binding var previewURL: URL?
    @Binding var errorText: String?

    @State private var files: [String] = []
    @State private var search = ""
    @State private var selection: String?
    @State private var versions: [FileVersion] = []
    @State private var loadingFiles = true
    @State private var loadingVersions = false
    @State private var fileRestore: FileRestoreRequest?

    var body: some View {
        let syncing = model.runtime[repoID]?.isSyncing == true
        SplitLayout(sidebarTitle: String(localized: "文件")) {
            TextField("搜索文件", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 12)
            List(filteredFiles, id: \.self, selection: $selection) { path in
                HStack(spacing: 8) {
                    Image(systemName: HistoryFormat.symbol(for: path)).foregroundStyle(.secondary).frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(HistoryFormat.fileName(path)).lineLimit(1)
                        let folder = HistoryFormat.folder(path)
                        if !folder.isEmpty {
                            Text(folder).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .overlay {
                if loadingFiles { ProgressView() }
                else if files.isEmpty { Text("没有已同步的文件").foregroundStyle(.secondary) }
            }
        } detail: {
            if let selection {
                versionList(for: selection)
            } else {
                ContentUnavailableView("选择一个文件", systemImage: "doc.text.magnifyingglass",
                                       description: Text("左侧列出最近一次同步时仓库中的所有文件。"))
            }
        }
        .task { await loadFiles() }
        .onChange(of: selection) { _, path in Task { await loadVersions(path) } }
        .reloadAfterSync(syncing) {
            await loadFiles()
            await loadVersions(selection)
        }
        .modifier(FileRestoreConfirmation(repoID: repoID, request: $fileRestore))
    }

    private var filteredFiles: [String] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return files }
        return files.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    private func versionList(for path: String) -> some View {
        let blocked = RestoreBlockedReason.text(model: model, repoID: repoID)
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(HistoryFormat.fileName(path)).font(.title3.bold()).lineLimit(1).truncationMode(.middle)
                Text("\(versions.filter { !$0.isDeletion }.count) 个版本 · \(path)")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .padding([.horizontal, .top], 16)
            List {
                ForEach(Array(versions.enumerated()), id: \.element.id) { index, version in
                    if version.isDeletion {
                        Label("\(HistoryFormat.relative(version.commit.date)) 被删除，后来又重新添加", systemImage: "trash")
                            .font(.callout).foregroundStyle(.secondary).padding(.vertical, 3)
                    } else {
                        FileActionRow(
                            path: path,
                            subtitle: subtitle(version, current: path),
                            badge: index == 0 ? String(localized: "最新同步版本") : nil,
                            restoreDisabledReason: index == 0 ? String(localized: "这就是最新同步的版本") : blocked,
                            onPreview: { preview(version) },
                            onSaveCopy: {
                                Task {
                                    await model.saveVersionCopy(repoID, path: version.path, commit: version.commit.id,
                                                                date: version.commit.date, besides: path)
                                }
                            },
                            onRestore: {
                                fileRestore = FileRestoreRequest(path: path, sourcePath: version.path,
                                                                 commit: version.commit.id, date: version.commit.date)
                            }
                        )
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .overlay {
                if loadingVersions { ProgressView() }
                else if versions.isEmpty { Text("没有找到历史版本").foregroundStyle(.secondary) }
            }
        }
    }

    private func subtitle(_ version: FileVersion, current: String) -> String {
        var parts = [HistoryFormat.relative(version.commit.date), version.commit.source, HistoryFormat.size(version.size)]
        if version.path != current { parts.append(String(localized: "当时名为「\(HistoryFormat.fileName(version.path))」")) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func loadFiles() async {
        guard let browser = model.historyBrowser(repoID) else { return }
        do {
            files = try await browser.trackedFiles()
        } catch {
            errorText = HistoryFormat.describe(error)
        }
        loadingFiles = false
    }

    private func loadVersions(_ path: String?) async {
        guard let path, let browser = model.historyBrowser(repoID) else {
            versions = []
            return
        }
        loadingVersions = true
        defer { loadingVersions = false }
        do {
            let loaded = try await browser.versions(of: path)
            if selection == path { versions = loaded }
        } catch {
            errorText = HistoryFormat.describe(error)
        }
    }

    private func preview(_ version: FileVersion) {
        guard let browser = model.historyBrowser(repoID) else { return }
        Task {
            do {
                previewURL = try await browser.exportForPreview(path: version.path, commit: version.commit.id, date: version.commit.date)
            } catch {
                errorText = HistoryFormat.describe(error)
            }
        }
    }
}

// MARK: - Recently deleted

private struct DeletedSplit: View {
    @Environment(AppModel.self) private var model
    let repoID: UUID
    @Binding var previewURL: URL?
    @Binding var errorText: String?

    @State private var files: [DeletedFile] = []
    @State private var selection: String?
    @State private var loading = true
    @State private var pendingRestore: DeletedFile?

    var body: some View {
        let syncing = model.runtime[repoID]?.isSyncing == true
        SplitLayout(sidebarTitle: String(localized: "已删除的文件")) {
            List(files, selection: $selection) { file in
                HStack(spacing: 8) {
                    Image(systemName: HistoryFormat.symbol(for: file.path)).foregroundStyle(.secondary).frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(HistoryFormat.fileName(file.path)).lineLimit(1).truncationMode(.middle)
                        Text("\(HistoryFormat.relative(file.deletedIn.date)) 删除").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
                .tag(file.id)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .overlay {
                if loading { ProgressView() }
                else if files.isEmpty { Text("没有已删除的文件").foregroundStyle(.secondary) }
            }
        } detail: {
            if let file = files.first(where: { $0.id == selection }) {
                detail(file)
            } else {
                ContentUnavailableView("选择一个已删除的文件", systemImage: "trash",
                                       description: Text("同步过、后来又被删除的文件会出现在左侧，可以预览或找回。"))
            }
        }
        .task { await load() }
        .reloadAfterSync(syncing) { await load() }
        .confirmationDialog("找回「\(pendingRestore.map { HistoryFormat.fileName($0.path) } ?? "")」？", isPresented: Binding(
            get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }
        )) {
            if let file = pendingRestore {
                Button("恢复到原位置") {
                    model.restore(repoID, target: .file(path: file.path, sourcePath: file.path, commit: file.lastVersionCommit),
                                  description: String(localized: "已删除的「\(HistoryFormat.fileName(file.path))」"))
                }
            }
        } message: {
            Text("文件将以删除前的最后一个版本放回「\(pendingRestore?.path ?? "")」，并作为一次新的同步上传到 GitHub。")
        }
    }

    private func detail(_ file: DeletedFile) -> some View {
        let blocked = RestoreBlockedReason.text(model: model, repoID: repoID)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: HistoryFormat.symbol(for: file.path)).font(.largeTitle).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(HistoryFormat.fileName(file.path)).font(.title3.bold()).lineLimit(2)
                    Text(file.path).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow { Text("删除时间").foregroundStyle(.secondary); Text(HistoryFormat.date(file.deletedIn.date)) }
                GridRow { Text("删除者").foregroundStyle(.secondary); Text(file.deletedIn.source) }
                GridRow { Text("大小").foregroundStyle(.secondary); Text(HistoryFormat.size(file.size).isEmpty ? "—" : HistoryFormat.size(file.size)) }
            }
            .font(.callout)
            HStack {
                Button { preview(file) } label: { Label("预览", systemImage: "eye") }
                Button {
                    Task { await model.saveVersionCopy(repoID, path: file.path, commit: file.lastVersionCommit, date: file.deletedIn.date) }
                } label: { Label("另存副本", systemImage: "plus.square.on.square") }
                Spacer()
                Button { pendingRestore = file } label: { Label("恢复到原位置…", systemImage: "arrow.uturn.backward") }
                    .buttonStyle(.borderedProminent)
                    .disabled(blocked != nil)
                    .help(blocked ?? "")
            }
            Spacer()
        }
        .padding(16)
    }

    private func load() async {
        guard let browser = model.historyBrowser(repoID) else { return }
        do {
            files = try await browser.deletedFiles()
            if selection == nil || !files.contains(where: { $0.id == selection }) { selection = files.first?.id }
        } catch {
            errorText = HistoryFormat.describe(error)
        }
        loading = false
    }

    private func preview(_ file: DeletedFile) {
        guard let browser = model.historyBrowser(repoID) else { return }
        Task {
            do {
                previewURL = try await browser.exportForPreview(path: file.path, commit: file.lastVersionCommit, date: file.deletedIn.date)
            } catch {
                errorText = HistoryFormat.describe(error)
            }
        }
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
