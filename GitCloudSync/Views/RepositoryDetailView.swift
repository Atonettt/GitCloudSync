import SwiftUI

/// The selected repository, filling the detail column: what it is, how it stands, what you can do
/// with it, and what happened recently.
struct RepositoryDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let repo: RepositoryConfig
    @State private var confirmRemove = false
    @State private var confirmAbort = false
    @State private var showActivity = false
    @State private var showPending = false
    @State private var showDetails = false

    var body: some View {
        let runtime = model.runtime[repo.id]
        let info = runtime?.info
        let status = model.displayStatus(for: repo)
        let syncing = runtime?.isSyncing == true

        VStack(alignment: .leading, spacing: 8) {
            header(status: status, phase: runtime?.phase, info: info)

            if repo.lastStatus == .conflict, !repo.conflictFiles.isEmpty, !syncing {
                ConflictSummaryView(repo: repo)
            } else if let failure = repo.lastFailure, repo.lastStatus.isProblem, !syncing {
                if failure.kind == .folderMissing {
                    MissingFolderView(repo: repo)
                } else {
                    FailureSummaryView(repo: repo, failure: failure, onAbort: { confirmAbort = true })
                }
            }

            if let warnings = runtime?.warnings, !warnings.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            HStack(alignment: .top, spacing: 12) {
                lastSyncTile(status: status)
                changesTile(info: info)
                spaceTile(usage: runtime?.usage, measuring: runtime?.measuringUsage == true)
            }

            actions(info: info, syncing: syncing)

            // The folder itself fills the rest: browse it and preview files.
            RepositoryFilesView(repo: repo)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .confirmationDialog("从列表移除「\(repo.displayName)」？", isPresented: $confirmRemove) {
            Button("移除", role: .destructive) { model.removeRepository(repo.id) }
        } message: {
            Text("只会从 GitSync 中移除，不会删除本地文件，也不会影响 GitHub 上的仓库。")
        }
        .confirmationDialog("中止未完成的 \(info?.inProgressOperation?.displayName ?? "Git") 操作？", isPresented: $confirmAbort) {
            Button("中止操作", role: .destructive) { Task { await model.abortInProgressOperation(repo.id) } }
        } message: {
            Text("将执行 git \(abortCommand(info?.inProgressOperation)) --abort，仓库回到该操作开始之前的状态。该操作过程中尚未提交的冲突解决内容会丢失；已提交的内容不受影响。如不确定，请改用 GitHub Desktop 处理。")
        }
    }

    // MARK: Sections

    private func header(status: SyncStatus, phase: SyncPhase?, info: RepositoryInfo?) -> some View {
        // One line: name, status and the sync controls.
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "folder.fill")
                .font(.system(size: 18))
                .foregroundStyle(.tint)
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Text(repo.displayName).font(.title3.bold()).lineLimit(1).truncationMode(.middle)
                    Button {
                        showDetails.toggle()
                    } label: {
                        Image(systemName: "info.circle").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .focusEffectDisabled()
                    .help("详细信息：路径、远程地址、分支")
                    .popover(isPresented: $showDetails, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("详细信息").font(.headline)
                            details(info: info)
                            Text("点击路径或远程地址即可复制。").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(14)
                        .frame(width: 460)
                    }
                }
                HStack(spacing: 6) {
                    StatusBadge(status: status)
                    if let phase {
                        Text(phase.displayName).font(.caption).foregroundStyle(.secondary)
                    } else if !repo.autoSyncEnabled {
                        Text("自动同步已关闭").font(.caption).foregroundStyle(.secondary)
                    } else if repo.pausedForConflict {
                        Text("因冲突暂停").font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            Spacer()
            // Both ways of syncing this repository sit together.
            HStack(spacing: 12) {
                Toggle("自动同步", isOn: Binding(
                    get: { repo.autoSyncEnabled },
                    set: { model.setAutoSync($0, for: repo.id) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(.green)   // green "on", so it isn't mistaken for the button next to it
                .help("打开后立即同步一次，之后按间隔自动同步")
                Divider().frame(height: 20)
                Button {
                    model.sync(repo.id, trigger: .manualSingle)
                } label: {
                    if model.runtime[repo.id]?.isSyncing == true {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("同步中…") }
                    } else {
                        Label("立即同步", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(model.runtime[repo.id]?.isSyncing == true || model.gitEnvironment == nil)
                .help("马上同步这个仓库")
            }
        }
    }

    private func lastSyncTile(status: SyncStatus) -> some View {
        StatTile(title: String(localized: "上次同步")) {
            Text(repo.lastSyncAt?.relativeDescription ?? String(localized: "从未成功同步"))
        } detail: {
            HStack(spacing: 6) {
                if let message = repo.lastMessage, !status.isActive {
                    Text(message).lineLimit(1)
                } else if let date = repo.lastSyncAt {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                }
                Button {
                    showActivity.toggle()
                } label: {
                    Label("同步记录", systemImage: "clock")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.accentColor)   // the tile's grey detail style would hide that it's clickable
                .fixedSize()
                .help("最近的同步记录")
                    .popover(isPresented: $showActivity, arrowEdge: .bottom) {
                        RecentActivityView(repo: repo)
                            .padding(14)
                            .frame(width: 460)
                    }
            }
        }
    }

    private func changesTile(info: RepositoryInfo?) -> some View {
        StatTile(title: String(localized: "待同步")) {
            if let info {
                if info.remoteURL == nil {
                    Text("未关联 GitHub").foregroundStyle(.orange)
                } else if info.changedFiles > 0 {
                    Text("\(info.changedFiles) 个未同步修改")
                } else {
                    Text("无未同步修改")
                }
            } else {
                Text("—")
            }
        } detail: {
            if let info, info.remoteURL != nil {
                HStack(spacing: 6) {
                    Text("待上传 \(info.ahead) · 待下载 \(info.behind)").lineLimit(1)
                    if info.changedFiles > 0 {
                        Button {
                            showPending.toggle()
                        } label: {
                            Label("查看", systemImage: "list.bullet")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Color.accentColor)
                        .fixedSize()
                        .help("查看还没同步的修改，可以还原为 GitHub 上的版本")
                        .popover(isPresented: $showPending, arrowEdge: .bottom) {
                            PendingChangesView(repo: repo)
                                .padding(14)
                                .frame(width: 460)
                        }
                    }
                }
            }
        }
    }

    private func spaceTile(usage: RepositoryUsage?, measuring: Bool) -> some View {
        StatTile(title: String(localized: "空间")) {
            if let usage {
                Text(ByteCountFormatter.string(fromByteCount: usage.fileBytes, countStyle: .file))
                    .foregroundStyle(usage.level == .normal ? Color.primary : (usage.level == .large ? .orange : .red))
            } else {
                Text(measuring ? String(localized: "正在计算…") : "—")
            }
        } detail: {
            if let usage {
                HStack(spacing: 6) {
                    Text("历史 \(ByteCountFormatter.string(fromByteCount: usage.historyBytes, countStyle: .file))")
                    Button("详情") { model.activeSheet = .storage(repo.id) }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
    }

    private func actions(info: RepositoryInfo?, syncing: Bool) -> some View {
        HStack(spacing: 8) {
            Button {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: WindowID.history, value: HistoryRequest(repoID: repo.id))
            } label: {
                Label("历史版本", systemImage: "clock.arrow.circlepath")
            }
            .disabled(model.gitEnvironment == nil || info?.isUnborn == true)
            .help("查看、预览和恢复以前同步过的版本")

            Button {
                model.revealInFinder(repo.id)
            } label: {
                Label("Finder", systemImage: "folder")
            }

            if info?.webURL != nil {
                Button {
                    model.openOnGitHub(repo.id)
                } label: {
                    Label("GitHub", systemImage: "safari")
                }
            }

            Spacer()

            Menu {
                if repo.lastFailure != nil {
                    Button("查看错误详情") { model.activeSheet = .errorDetail(repo.id) }
                }
                if !repo.conflictFiles.isEmpty {
                    Button("解决冲突…") { model.activeSheet = .conflicts(repo.id) }
                }
                if info?.inProgressOperation != nil {
                    Button("中止未完成的 Git 操作…") { confirmAbort = true }
                }
                if let info, info.remoteURL == nil {
                    Divider()
                    Button("在 GitHub 上创建仓库…") { model.activeSheet = .createRepository(URL(fileURLWithPath: repo.path)) }
                }
                Divider()
                Button("从列表移除…") { confirmRemove = true }
                if info?.isGitHubRemote == true {
                    Button("删除 GitHub 上的仓库…", role: .destructive) {
                        model.activeSheet = .deleteRepository(repo.id, github: true, local: false)
                    }
                }
                Button("删除本地文件夹…", role: .destructive) {
                    model.activeSheet = .deleteRepository(repo.id, github: false, local: true)
                }
                .disabled(syncing)
            } label: {
                Label("更多", systemImage: "ellipsis.circle")
            }
            .fixedSize()
        }
        .controlSize(.regular)
    }

    private func details(info: RepositoryInfo?) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                label(String(localized: "路径"))
                CopyableText(text: repo.path)
            }
            GridRow {
                label(String(localized: "远程"))
                if let remote = info?.remoteURL {
                    CopyableText(text: remote)
                } else {
                    Text(info == nil ? "—" : String(localized: "未配置 origin")).foregroundStyle(.orange)
                }
            }
            GridRow {
                label(String(localized: "分支"))
                HStack(spacing: 12) {
                    Text(info?.branch ?? (info == nil ? "—" : String(localized: "分离 HEAD")))
                    if let info, info.upstream == nil, info.remoteURL != nil {
                        Text("远程分支尚不存在").foregroundStyle(.secondary)
                    }
                }
            }
            GridRow {
                label(String(localized: "添加时间"))
                Text(repo.addedAt.formatted(date: .abbreviated, time: .shortened))
            }
        }
        .font(.callout)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .insetBackground(cornerRadius: 10)
    }

    private func label(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }

    private func abortCommand(_ op: InProgressOperation?) -> String {
        switch op {
        case .rebase: "rebase"
        case .cherryPick: "cherry-pick"
        case .revert: "revert"
        default: "merge"
        }
    }
}

struct FailureSummaryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    let repo: RepositoryConfig
    let failure: SyncFailure
    let onAbort: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: failure.mappedStatus.symbol).foregroundStyle(failure.mappedStatus.color)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(failure.stage.displayName)：\(failure.message)").font(.callout.weight(.medium))
                if let firstLine = failure.stderr.split(separator: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                    Text(firstLine).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                }
                Text(failure.suggestion).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Button("查看详情") { model.activeSheet = .errorDetail(repo.id) }
                if failure.mappedStatus == .needsAuth {
                    Button("重新登录") { openSettings() }
                }
                if failure.kind == .operationInProgress, model.runtime[repo.id]?.info?.inProgressOperation != nil {
                    Button("中止操作…", action: onAbort)
                }
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(failure.mappedStatus.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ConflictSummaryView: View {
    @Environment(AppModel.self) private var model
    let repo: RepositoryConfig

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(repo.conflictFiles.count) 个文件在本地和 GitHub 上都被修改，已暂停此仓库的自动同步。")
                    .font(.callout.weight(.medium))
                Text("没有覆盖任何文件：磁盘上仍是你本地的版本，GitHub 上仍是远程版本。")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(repo.conflictFiles.prefix(5)) { file in
                    Text("• \(file.path)").font(.caption.monospaced())
                }
                if repo.conflictFiles.count > 5 {
                    Text("……以及另外 \(repo.conflictFiles.count - 5) 个").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("解决冲突…") { model.activeSheet = .conflicts(repo.id) }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
        }
        .padding(10)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Shown when a repository's folder can't be found: put it back from the Trash, use a location
/// Spotlight found, or point GitSync at the folder's new place.
struct MissingFolderView: View {
    @Environment(AppModel.self) private var model
    let repo: RepositoryConfig
    @State private var confirmRemove = false

    var body: some View {
        let runtime = model.runtime[repo.id]
        let trashed = runtime?.trashedURL != nil
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: trashed ? "trash" : "questionmark.folder").foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 3) {
                    if trashed {
                        Text("「\(repo.displayName)」在废纸篓中").font(.callout.weight(.medium))
                        Text("放回原处后会继续同步。").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("找不到文件夹「\(repo.displayName)」").font(.callout.weight(.medium))
                        Text("原来的位置：\(repo.path)。如果移动过它，选出新位置后会继续同步；如果已经删除，可以从 GitHub 重新下载。设置和历史都保留。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            if !trashed {
                if runtime?.searchingCandidates == true {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("正在查找可能的新位置…")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(runtime?.candidates ?? [], id: \.self) { url in
                    HStack {
                        Label(url.path, systemImage: "folder").font(.caption).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("使用这个位置") { relocate(to: url) }
                    }
                }
            }
            HStack {
                if trashed {
                    Button("放回原处") { Task { await model.putBackFromTrash(repo.id) } }
                        .buttonStyle(.borderedProminent)
                }
                if runtime?.downloading == true {
                    ProgressView().controlSize(.small)
                    Text("正在从 GitHub 下载…").font(.caption).foregroundStyle(.secondary)
                } else {
                    Menu {
                        Button("下载到原来的位置") { Task { await model.redownload(repo.id) } }
                        Button("下载到其他位置…") { chooseDownloadLocation() }
                    } label: {
                        Label("从 GitHub 重新下载", systemImage: "icloud.and.arrow.down")
                    } primaryAction: {
                        Task { await model.redownload(repo.id) }
                    }
                    .menuStyle(.button)
                    .fixedSize()
                    Button("重新定位…") { chooseFolder() }
                    Button("从列表移除…") { confirmRemove = true }
                }
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .confirmationDialog("从列表移除「\(repo.displayName)」？", isPresented: $confirmRemove) {
            Button("移除", role: .destructive) { model.removeRepository(repo.id) }
        } message: {
            Text("只会从 GitSync 中移除，不会删除本地文件，也不会影响 GitHub 上的仓库。")
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "重新定位「\(repo.displayName)」")
        panel.message = String(localized: "选择这个仓库现在所在的文件夹")
        panel.prompt = String(localized: "使用这个文件夹")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        let parent = URL(fileURLWithPath: repo.path).deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: parent.path) { panel.directoryURL = parent }
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        relocate(to: url)
    }

    /// Asks for the folder to download into; the repository goes into a new folder with its name.
    private func chooseDownloadLocation() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "从 GitHub 重新下载「\(repo.displayName)」")
        panel.message = String(localized: "选择放在哪个文件夹里，会在里面新建「\(URL(fileURLWithPath: repo.path).lastPathComponent)」")
        panel.prompt = String(localized: "下载到这里")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        let destination = parent.appendingPathComponent(URL(fileURLWithPath: repo.path).lastPathComponent, isDirectory: true)
        Task { await model.redownload(repo.id, to: destination) }
    }

    private func relocate(to url: URL) {
        Task {
            if let error = await model.relocate(repo.id, to: url) {
                model.alert = AppAlert(title: String(localized: "无法使用这个文件夹"), message: error)
            }
        }
    }
}

/// A small titled figure with an optional detail line, shown in a row of three.
private struct StatTile<Value: View, Detail: View>: View {
    let title: String
    @ViewBuilder let value: Value
    @ViewBuilder let detail: Detail

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            value.font(.headline).lineLimit(1)
            detail.font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .insetBackground(cornerRadius: 10)
    }
}

/// The latest log entries for one repository, so the detail column shows what actually happened.
private struct RecentActivityView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let repo: RepositoryConfig

    var body: some View {
        let entries = Array(model.logStore.entries.lazy.filter { $0.repositoryID == repo.id }.prefix(8))
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("最近同步记录").font(.headline)
                Spacer()
                Button("查看全部日志") { openWindow(id: WindowID.logs) }
                    .buttonStyle(.link)
            }
            if entries.isEmpty {
                Text("暂无同步活动").font(.callout).foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .insetBackground(cornerRadius: 10)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: entry.level.symbol).foregroundStyle(entry.level.color)
                            Text(entry.date.formatted(.dateTime.month().day().hour().minute()))
                                .monospacedDigit().foregroundStyle(.secondary)
                                .frame(width: 110, alignment: .leading)
                            Text(text(of: entry)).lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 0)
                        }
                        .font(.callout)
                        .padding(.vertical, 7)
                        if index < entries.count - 1 { Divider() }
                    }
                }
                .padding(.horizontal, 12)
                .insetBackground(cornerRadius: 10)
            }
        }
    }

    /// Log lines start with the repository name, which is redundant here.
    private func text(of entry: SyncLogEntry) -> String {
        for separator in ["：", ": "] where entry.result.hasPrefix(repo.displayName + separator) {
            return String(entry.result.dropFirst(repo.displayName.count + separator.count))
        }
        return entry.result
    }
}

/// A value that copies itself when clicked, with a brief confirmation.
private struct CopyableText: View {
    let text: String
    @State private var copied = false
    @State private var hovering = false

    var body: some View {
        Button {
            Clipboard.copy(text)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            HStack(spacing: 6) {
                Text(text).lineLimit(1).truncationMode(.middle)
                    .underline(hovering && !copied, color: .secondary)
                if copied {
                    Label("已复制", systemImage: "checkmark").font(.caption).foregroundStyle(.green)
                } else {
                    Image(systemName: "doc.on.doc").font(.caption).foregroundStyle(.secondary)
                        .opacity(hovering ? 1 : 0)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()   // the popover gives it keyboard focus on opening; no ring needed
        .onHover { hovering = $0 }
        .help("点击复制")
    }
}

/// Local changes that are not on GitHub yet. Edited and deleted files can be put back to their
/// GitHub version; new files exist only here, so there is nothing to put back.
private struct PendingChangesView: View {
    @Environment(AppModel.self) private var model
    let repo: RepositoryConfig
    @State private var entries: [StatusEntry] = []
    @State private var loaded = false
    @State private var confirm: [String]?

    private var revertible: [StatusEntry] { entries.filter { !$0.isUntracked } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("未同步的修改").font(.headline)
                Spacer()
                if revertible.count > 1 {
                    Button("全部还原为云端版本…") { confirm = revertible.map(\.path) }
                        .controlSize(.small)
                }
            }
            if !loaded {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            } else if entries.isEmpty {
                Text("没有未同步的修改").foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(entries, id: \.self) { entry in
                            row(entry)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 320)
                .fixedSize(horizontal: false, vertical: true)
            }
            Text("还原会丢弃本机还没同步的修改，换回 GitHub 上现在的内容；丢弃的内容会在本机保留一份备份。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task(id: model.runtime[repo.id]?.isSyncing) {
            entries = await model.pendingChanges(repo.id)
            loaded = true
        }
        .confirmationDialog(
            confirm?.count == 1
                ? String(localized: "将「\(URL(fileURLWithPath: confirm?.first ?? "").lastPathComponent)」还原为 GitHub 上的版本？")
                : String(localized: "将 \(confirm?.count ?? 0) 个文件还原为 GitHub 上的版本？"),
            isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
            presenting: confirm
        ) { paths in
            Button("还原", role: .destructive) { model.revertToCloud(repo.id, paths: paths) }
        } message: { _ in
            Text("本机还没同步的修改会被丢弃，丢弃的内容会在本机保留一份备份。")
        }
    }

    private func row(_ entry: StatusEntry) -> some View {
        let (label, color): (String, Color) = entry.isUntracked
            ? (String(localized: "新增"), .green)
            : entry.isDeletion ? (String(localized: "已删除"), .red) : (String(localized: "已修改"), .orange)
        return HStack(spacing: 8) {
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(color)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(color.opacity(0.12), in: Capsule())
                .frame(width: 48)
            Text(entry.path).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(entry.path)
            if entry.isUntracked {
                Text("只在本机").font(.caption).foregroundStyle(.tertiary)
            } else {
                Button("还原") { confirm = [entry.path] }
                    .controlSize(.small)
                    .disabled(model.runtime[repo.id]?.isSyncing == true)
            }
        }
        .padding(.vertical, 5)
    }
}
