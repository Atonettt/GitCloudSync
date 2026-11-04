import SwiftUI

struct RepositoryCardView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let repo: RepositoryConfig
    @State private var confirmRemove = false
    @State private var confirmAbort = false
    /// Remembered per repository across launches.
    @AppStorage private var expanded: Bool

    init(repo: RepositoryConfig) {
        self.repo = repo
        _expanded = AppStorage(wrappedValue: false, "repoCard.expanded.\(repo.id.uuidString)")
    }

    var body: some View {
        let runtime = model.runtime[repo.id]
        let info = runtime?.info
        let status = model.displayStatus(for: repo)
        let syncing = runtime?.isSyncing == true

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "folder.fill").foregroundStyle(.tint)
                Text(repo.displayName).font(.headline)
                StatusBadge(status: status)
                if let phase = runtime?.phase {
                    Text(phase.displayName).font(.caption).foregroundStyle(.secondary)
                }
                if !repo.autoSyncEnabled {
                    Text("自动同步已关闭").font(.caption).foregroundStyle(.secondary)
                } else if repo.pausedForConflict {
                    Text("因冲突暂停").font(.caption).foregroundStyle(.orange)
                }
                Spacer()
                Toggle("自动同步", isOn: Binding(
                    get: { repo.autoSyncEnabled },
                    set: { model.setAutoSync($0, for: repo.id) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("打开后立即同步一次，之后按间隔自动同步")
            }

            // One summary line; the full details fold away so the list stays easy to scan.
            HStack(spacing: 10) {
                Text(repo.lastSyncAt.map { String(localized: "\($0.relativeDescription)同步") } ?? String(localized: "从未成功同步"))
                if let message = repo.lastMessage, !status.isActive {
                    Text("· \(message)").foregroundStyle(.secondary).lineLimit(1)
                }
                if let info {
                    if info.changedFiles > 0 {
                        Label("\(info.changedFiles) 个未同步修改", systemImage: "pencil.circle")
                    }
                    if info.ahead > 0 { Label("待上传 \(info.ahead)", systemImage: "arrow.up") }
                    if info.behind > 0 { Label("待下载 \(info.behind)", systemImage: "arrow.down") }
                    if info.remoteURL == nil {
                        Label("未关联 GitHub", systemImage: "link.badge.plus").foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 8)
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 3) {
                        Text(expanded ? String(localized: "收起") : String(localized: "详细信息"))
                        Image(systemName: "chevron.down")
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
            .font(.callout)

            HStack(spacing: 10) {
                Text("空间").foregroundStyle(.secondary)
                UsageSummaryView(repoID: repo.id)
            }
            .font(.callout)

            if expanded {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                    GridRow {
                        label(String(localized: "路径"))
                        Text(repo.path).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    }
                    GridRow {
                        label(String(localized: "远程"))
                        if let remote = info?.remoteURL {
                            Text(remote).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
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
                        label(String(localized: "最近同步"))
                        Text(repo.lastSyncAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? String(localized: "从未成功同步"))
                    }
                }
                .font(.callout)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .insetBackground(cornerRadius: 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
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

            if repo.lastStatus == .conflict, !repo.conflictFiles.isEmpty, !syncing {
                ConflictSummaryView(repo: repo)
            } else if let failure = repo.lastFailure, repo.lastStatus.isProblem, !syncing {
                FailureSummaryView(repo: repo, failure: failure, onAbort: { confirmAbort = true })
            }

            HStack(spacing: 8) {
                Button {
                    model.sync(repo.id, trigger: .manualSingle)
                } label: {
                    if syncing {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("同步中…") }
                    } else {
                        Label("立即同步", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(syncing || model.gitEnvironment == nil)

                Button {
                    model.revealInFinder(repo.id)
                } label: {
                    Label("Finder", systemImage: "folder")
                }

                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: WindowID.history, value: repo.id)
                } label: {
                    Label("历史版本", systemImage: "clock.arrow.circlepath")
                }
                .disabled(model.gitEnvironment == nil || info?.isUnborn == true)
                .help("查看、预览和恢复以前同步过的版本")

                if info?.webURL != nil {
                    Button {
                        model.openOnGitHub(repo.id)
                    } label: {
                        Label("GitHub", systemImage: "safari")
                    }
                }

                Spacer()

                Menu {
                    // Auto sync and disk usage have their own controls on the card.
                    Button("重新检测仓库信息") { Task { await model.refreshInfo(repo.id) } }
                    if repo.lastFailure != nil {
                        Button("查看错误详情") { model.activeSheet = .errorDetail(repo.id) }
                    }
                    if !repo.conflictFiles.isEmpty {
                        Button("解决冲突…") { model.activeSheet = .conflicts(repo.id) }
                    }
                    if info?.inProgressOperation != nil {
                        Button("中止未完成的 Git 操作…") { confirmAbort = true }
                    }
                    Divider()
                    Button("复制路径") { Clipboard.copy(repo.path) }
                    if let remote = info?.remoteURL {
                        Button("复制远程地址") { Clipboard.copy(remote) }
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
        .padding(14)
        .glassPanel(tint: status.isProblem ? status.color : nil)
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
