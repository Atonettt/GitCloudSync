import QuickLook
import SwiftUI

/// Browse, preview and restore versions recorded by earlier syncs.
struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let repoID: UUID

    enum Tab: String, CaseIterable, Identifiable {
        case files = "文件历史"
        case deleted = "最近删除"
        case timeline = "整个仓库"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .files
    @State private var previewURL: URL?
    @State private var errorText: String?

    var body: some View {
        let repo = model.repository(repoID)
        let runtime = model.runtime[repoID]
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Image(systemName: "clock.arrow.circlepath").font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("历史版本 — \(repo?.displayName ?? "")").font(.title3.bold())
                    Text("每次同步保存一个版本，只能恢复到同步时的状态；两次同步之间的中间修改无法找回。"
                         + (repo?.lastSyncAt.map { " 最近一次同步：\($0.formatted(date: .abbreviated, time: .shortened))。" } ?? ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 270)
            }

            Group {
                switch tab {
                case .files: FileHistoryTab(repoID: repoID, previewURL: $previewURL, errorText: $errorText)
                case .deleted: DeletedFilesTab(repoID: repoID, previewURL: $previewURL, errorText: $errorText)
                case .timeline: TimelineTab(repoID: repoID, errorText: $errorText)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 8) {
                if runtime?.isSyncing == true {
                    ProgressView().controlSize(.small)
                    Text(runtime?.phase?.displayName ?? "正在同步…").font(.callout).foregroundStyle(.secondary)
                } else if repo?.pausedForConflict == true {
                    Label("此仓库存在冲突，请先解决冲突再恢复版本", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                } else if let message = repo?.lastMessage, repo?.lastStatus.isProblem == true {
                    Label(message, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange)
                }
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 760, height: 540)
        .quickLookPreview($previewURL)
        .alert("操作失败", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("好") { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
    }
}

// MARK: - Shared helpers

private extension View {
    /// Re-runs `reload` when a sync or restore of this repository finishes.
    func reloadAfterSync(_ syncing: Bool, _ reload: @escaping () async -> Void) -> some View {
        onChange(of: syncing) { _, now in
            if !now { Task { await reload() } }
        }
    }
}

private enum HistoryFormat {
    static func date(_ date: Date) -> String {
        date.formatted(.dateTime.year().month().day().hour().minute())
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static func size(_ bytes: Int64?) -> String {
        bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""
    }

    static func fileName(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    static func describe(_ error: Error) -> String {
        (error as? SyncFailure)?.fullReport ?? error.localizedDescription
    }
}

private enum RestoreBlockedReason {
    @MainActor
    static func text(model: AppModel, repoID: UUID) -> String? {
        if model.runtime[repoID]?.isSyncing == true { return "正在同步，请稍候" }
        if model.repository(repoID)?.pausedForConflict == true { return "请先解决冲突" }
        return nil
    }
}

// MARK: - File history

private struct FileHistoryTab: View {
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
    @State private var pendingRestore: FileVersion?

    var body: some View {
        let syncing = model.runtime[repoID]?.isSyncing == true
        HStack(spacing: 0) {
            VStack(spacing: 8) {
                TextField("搜索文件", text: $search).textFieldStyle(.roundedBorder)
                List(filteredFiles, id: \.self, selection: $selection) { path in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(HistoryFormat.fileName(path)).lineLimit(1)
                        let folder = (path as NSString).deletingLastPathComponent
                        if !folder.isEmpty {
                            Text(folder).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                .overlay {
                    if loadingFiles { ProgressView() }
                    else if files.isEmpty { Text("没有已同步的文件").foregroundStyle(.secondary) }
                }
            }
            .frame(width: 250)
            .padding(.trailing, 12)

            Divider()

            Group {
                if let selection {
                    versionList(for: selection)
                } else {
                    ContentUnavailableView("选择一个文件", systemImage: "doc.text.magnifyingglass",
                                           description: Text("左侧列出最近一次同步时仓库中的所有文件。"))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.leading, 12)
        }
        .task { await loadFiles() }
        .onChange(of: selection) { _, path in
            Task { await loadVersions(path) }
        }
        .reloadAfterSync(syncing) {
            await loadFiles()
            await loadVersions(selection)
        }
        .confirmationDialog(confirmTitle, isPresented: Binding(
            get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }
        )) {
            if let version = pendingRestore, let current = selection {
                Button("恢复为这个版本") { restore(version, current: current) }
                Button("改为另存副本") { saveCopy(version, current: current) }
            }
        } message: {
            Text("当前版本不会丢失：恢复前会先保存未同步的修改并创建备份，恢复本身作为一次新的同步上传，以后也可以在历史中再恢复回来。另一台 Mac 会在下次同步时收到这个版本。")
        }
    }

    private var filteredFiles: [String] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return files }
        return files.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    private var confirmTitle: String {
        guard let version = pendingRestore, let current = selection else { return "" }
        return "将「\(HistoryFormat.fileName(current))」恢复到 \(HistoryFormat.date(version.commit.date)) 的版本？"
    }

    @ViewBuilder
    private func versionList(for path: String) -> some View {
        let blocked = RestoreBlockedReason.text(model: model, repoID: repoID)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(path).font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text("\(versions.filter { !$0.isDeletion }.count) 个版本").font(.caption).foregroundStyle(.secondary)
            }
            List {
                ForEach(Array(versions.enumerated()), id: \.element.id) { index, version in
                    HStack(spacing: 10) {
                        Image(systemName: version.isDeletion ? "trash" : (index == 0 ? "checkmark.circle.fill" : "doc"))
                            .foregroundStyle(version.isDeletion ? Color.secondary : (index == 0 ? Color.green : Color.accentColor))
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(HistoryFormat.date(version.commit.date)).font(.callout.weight(.medium))
                                if index == 0, !version.isDeletion {
                                    Text("最新同步版本").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(Color.green.opacity(0.15), in: Capsule())
                                }
                            }
                            Text(subtitle(version, current: path)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if version.isDeletion {
                            Text("此时被删除，后来又重新添加").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text(HistoryFormat.size(version.size)).font(.caption).foregroundStyle(.secondary)
                            Button { preview(version) } label: { Image(systemName: "eye") }
                                .help("用快速查看预览这个版本")
                            Button { saveCopy(version, current: path) } label: { Image(systemName: "plus.square.on.square") }
                                .help("另存为「文件名 (日期 版本)」，当前文件不变")
                            Button("恢复…") { pendingRestore = version }
                                .disabled(index == 0 || blocked != nil)
                                .help(index == 0 ? "这就是最新同步的版本" : (blocked ?? "把当前文件恢复为这个版本"))
                        }
                    }
                    .buttonStyle(.borderless)
                    .padding(.vertical, 3)
                }
            }
            .overlay {
                if loadingVersions { ProgressView() }
                else if versions.isEmpty { Text("没有找到历史版本").foregroundStyle(.secondary) }
            }
        }
    }

    private func subtitle(_ version: FileVersion, current: String) -> String {
        var parts = [version.commit.source, version.commit.title]
        if version.path != current { parts.append("当时名为「\(version.path)」") }
        return parts.joined(separator: " · ")
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

    private func saveCopy(_ version: FileVersion, current: String) {
        Task {
            await model.saveVersionCopy(repoID, path: version.path, commit: version.commit.id,
                                        date: version.commit.date, besides: current)
        }
    }

    private func restore(_ version: FileVersion, current: String) {
        let description = "「\(HistoryFormat.fileName(current))」到 \(HistoryFormat.date(version.commit.date)) 的版本"
        model.restore(repoID, target: .file(path: current, sourcePath: version.path, commit: version.commit.id),
                      description: description)
    }
}

// MARK: - Deleted files

private struct DeletedFilesTab: View {
    @Environment(AppModel.self) private var model
    let repoID: UUID
    @Binding var previewURL: URL?
    @Binding var errorText: String?

    @State private var files: [DeletedFile] = []
    @State private var loading = true
    @State private var pendingRestore: DeletedFile?

    var body: some View {
        let syncing = model.runtime[repoID]?.isSyncing == true
        let blocked = RestoreBlockedReason.text(model: model, repoID: repoID)
        List {
            ForEach(files) { file in
                HStack(spacing: 10) {
                    Image(systemName: "doc.badge.ellipsis").foregroundStyle(.secondary).frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.path).lineLimit(1).truncationMode(.middle)
                        Text("\(HistoryFormat.date(file.deletedIn.date)) 由 \(file.deletedIn.source) 删除")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(HistoryFormat.size(file.size)).font(.caption).foregroundStyle(.secondary)
                    Button { preview(file) } label: { Image(systemName: "eye") }
                        .help("预览删除前的最后一个版本")
                    Button { saveCopy(file) } label: { Image(systemName: "plus.square.on.square") }
                        .help("另存为「文件名 (日期 版本)」")
                    Button("恢复…") { pendingRestore = file }
                        .disabled(blocked != nil)
                        .help(blocked ?? "把文件恢复到原来的位置")
                }
                .buttonStyle(.borderless)
                .padding(.vertical, 3)
            }
        }
        .overlay {
            if loading { ProgressView() }
            else if files.isEmpty {
                ContentUnavailableView("没有已删除的文件", systemImage: "trash.slash",
                                       description: Text("同步过、后来又被删除的文件会出现在这里。"))
            }
        }
        .task { await load() }
        .reloadAfterSync(syncing) { await load() }
        .confirmationDialog("恢复「\(pendingRestore.map { HistoryFormat.fileName($0.path) } ?? "")」？", isPresented: Binding(
            get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }
        )) {
            if let file = pendingRestore {
                Button("恢复到原位置") {
                    model.restore(repoID, target: .file(path: file.path, sourcePath: file.path, commit: file.lastVersionCommit),
                                  description: "已删除的「\(HistoryFormat.fileName(file.path))」")
                }
            }
        } message: {
            Text("文件将以删除前的最后一个版本放回「\(pendingRestore?.path ?? "")」，并作为一次新的同步上传到 GitHub。")
        }
    }

    private func load() async {
        guard let browser = model.historyBrowser(repoID) else { return }
        do {
            files = try await browser.deletedFiles()
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

    private func saveCopy(_ file: DeletedFile) {
        Task {
            await model.saveVersionCopy(repoID, path: file.path, commit: file.lastVersionCommit, date: file.deletedIn.date)
        }
    }
}

// MARK: - Whole repository timeline

private struct TimelineTab: View {
    @Environment(AppModel.self) private var model
    let repoID: UUID
    @Binding var errorText: String?

    private static let pageSize = 150

    @State private var commits: [HistoryCommit] = []
    @State private var loading = true
    @State private var canLoadMore = false
    @State private var pending: PendingRestore?
    @State private var alreadyCurrent: HistoryCommit?

    struct PendingRestore: Identifiable {
        let commit: HistoryCommit
        let preview: RestorePreview
        var id: String { commit.id }
    }

    var body: some View {
        let syncing = model.runtime[repoID]?.isSyncing == true
        let blocked = RestoreBlockedReason.text(model: model, repoID: repoID)
        List {
            ForEach(days, id: \.day) { group in
                Section(group.day.formatted(date: .complete, time: .omitted)) {
                    ForEach(group.commits) { commit in
                        row(commit, isLatest: commit.id == commits.first?.id, blocked: blocked)
                    }
                }
            }
            if canLoadMore {
                Button("加载更早的记录") { Task { await load(more: true) } }
                    .frame(maxWidth: .infinity)
            }
        }
        .overlay {
            if loading && commits.isEmpty { ProgressView() }
        }
        .task { await load(more: false) }
        .reloadAfterSync(syncing) { await load(more: false) }
        .sheet(item: $pending) { item in
            RepositoryRestoreConfirmView(commit: item.commit, preview: item.preview) {
                model.restore(repoID, target: .repository(commit: item.commit.id),
                              description: "整个仓库到 \(HistoryFormat.date(item.commit.date)) 的状态")
            }
        }
        .alert("已经是这个时间点的状态", isPresented: Binding(
            get: { alreadyCurrent != nil }, set: { if !$0 { alreadyCurrent = nil } }
        )) {
            Button("好") { alreadyCurrent = nil }
        } message: {
            Text("最新同步的内容与 \(alreadyCurrent.map { HistoryFormat.date($0.date) } ?? "") 时完全相同，无需恢复。")
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

    private func row(_ commit: HistoryCommit, isLatest: Bool, blocked: String?) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(commit.changes.prefix(50).enumerated()), id: \.offset) { _, change in
                    Text("\(change.displayStatus)  \(change.oldPath.map { "\($0) → " } ?? "")\(change.path)")
                        .font(.caption.monospaced())
                        .lineLimit(1).truncationMode(.middle)
                }
                if commit.changes.count > 50 {
                    Text("……以及另外 \(commit.changes.count - 50) 个文件").font(.caption).foregroundStyle(.secondary)
                }
                if commit.changes.isEmpty {
                    Text("没有文件变化").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 4)
        } label: {
            HStack(spacing: 10) {
                Text(HistoryFormat.time(commit.date)).font(.callout.monospacedDigit().weight(.medium)).frame(width: 56, alignment: .leading)
                Image(systemName: symbol(commit)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(commit.title).lineLimit(1)
                    Text("\(commit.source) · \(commit.changes.count) 个文件").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if isLatest {
                    Text("当前").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.green.opacity(0.15), in: Capsule())
                } else {
                    Button("回到这个时间点…") { Task { await prepare(commit) } }
                        .buttonStyle(.borderless)
                        .disabled(blocked != nil)
                        .help(blocked ?? "先预览会改动哪些文件，确认后再恢复")
                }
            }
        }
    }

    private func symbol(_ commit: HistoryCommit) -> String {
        switch commit.kind {
        case .autoSync: "arrow.up.circle"
        case .merge: "arrow.down.circle"
        case .restore: "clock.arrow.circlepath"
        case .other: "circle"
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
        } catch {
            errorText = HistoryFormat.describe(error)
        }
    }

    private func prepare(_ commit: HistoryCommit) async {
        guard let browser = model.historyBrowser(repoID) else { return }
        do {
            let preview = try await browser.previewRestore(to: commit.id)
            if preview.isEmpty {
                alreadyCurrent = commit
            } else {
                pending = PendingRestore(commit: commit, preview: preview)
            }
        } catch {
            errorText = HistoryFormat.describe(error)
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
            Text("共 \(preview.total) 个文件会改变。未同步的本地修改会先保存进历史，并创建备份；恢复作为一次新的同步上传，之后仍可在时间线中回到现在的状态。")
                .font(.callout).foregroundStyle(.secondary)
            List {
                section("改回旧内容", preview.modified, symbol: "pencil", color: .accentColor)
                section("找回（之后被删除的文件）", preview.restored, symbol: "plus.circle", color: .green)
                section("移除（之后新建的文件，仍保留在历史中）", preview.removed, symbol: "minus.circle", color: .orange)
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
