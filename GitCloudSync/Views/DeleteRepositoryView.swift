import SwiftUI

/// Deletes the GitHub repository and/or moves the local folder to the Trash, independently.
struct DeleteRepositoryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let repoID: UUID
    @State var deleteOnGitHub: Bool
    @State var deleteLocal: Bool

    @State private var localCheck: DeletionCheck?
    @State private var remoteCheck: DeletionCheck?
    @State private var remoteCheckError: String?
    @State private var checking = false
    @State private var confirmation = ""
    @State private var working = false
    @State private var errorText: String?
    @State private var needsScope = false

    private static let scopeCommand = "gh auth refresh -h github.com -s delete_repo"

    init(repoID: UUID, deleteOnGitHub: Bool, deleteLocal: Bool) {
        self.repoID = repoID
        _deleteOnGitHub = State(initialValue: deleteOnGitHub)
        _deleteLocal = State(initialValue: deleteLocal)
    }

    var body: some View {
        let repo = model.repository(repoID)
        let info = model.runtime[repoID]?.info
        let target = info?.remoteURL.flatMap(RepositoryRemoval.gitHubFullName(fromRemote:))
        let fullName = target.map { "\($0.owner)/\($0.name)" }
        let syncing = model.runtime[repoID]?.isSyncing == true && !working

        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "trash").font(.title).foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 3) {
                    Text("删除「\(repo?.displayName ?? "")」").font(.title3.bold())
                    Text("两项互不影响：只删 GitHub 时本地文件夹和全部历史都保留；只删本地时 GitHub 上的仓库保留。")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: $deleteOnGitHub) {
                        Text("删除 GitHub 上的仓库").font(.headline)
                    }
                    .disabled(fullName == nil)
                    Text(fullName.map { "github.com/\($0) — 永久删除仓库及其在 GitHub 上的全部历史。GitHub 通常允许在 90 天内从账号设置中恢复，但不要依赖这一点。" }
                         ?? "这个仓库的远程不是 GitHub，无法从这里删除。")
                        .font(.caption).foregroundStyle(.secondary)
                    if deleteOnGitHub {
                        remoteStatus
                        if !deleteLocal {
                            Label("删除后此文件夹变成仅本地、暂停同步；以后可在「更多」中重新发布到新的 GitHub 仓库。另一台 Mac 上的这个仓库将无法再同步。",
                                  systemImage: "info.circle")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: $deleteLocal) {
                        Text("删除本地文件夹").font(.headline)
                    }
                    Text("\(repo?.path ?? "") — 移到废纸篓（可以从废纸篓放回），并从列表移除。")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                    if deleteLocal { localStatus }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            if deleteOnGitHub, let fullName {
                VStack(alignment: .leading, spacing: 4) {
                    Text("请输入 \(fullName) 确认删除 GitHub 上的仓库：").font(.callout)
                    TextField(fullName, text: $confirmation).textFieldStyle(.roundedBorder)
                }
            }

            if needsScope {
                VStack(alignment: .leading, spacing: 6) {
                    Label("GitHub 拒绝了删除：当前登录的令牌没有删除仓库的权限（delete_repo）。", systemImage: "person.badge.key.fill")
                        .foregroundStyle(.orange)
                    Text("使用 GitHub CLI 登录时，在终端执行下面的命令授权一次，然后回到这里再点删除。使用个人访问令牌时，经典令牌需勾选 delete_repo，细粒度令牌需授予 Administration 读写。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text(Self.scopeCommand).font(.callout.monospaced()).textSelection(.enabled)
                        Button("复制") { Clipboard.copy(Self.scopeCommand) }
                    }
                }
                .font(.callout)
            }

            if let errorText {
                Text(errorText).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }

            Spacer(minLength: 0)

            HStack {
                if working {
                    ProgressView().controlSize(.small)
                    Text("正在删除…").foregroundStyle(.secondary)
                } else if syncing {
                    Text("正在同步，请等同步结束").foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(working)
                Button(buttonTitle, role: .destructive) { Task { await perform() } }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(working || syncing || checking || (!deleteOnGitHub && !deleteLocal)
                              || (deleteOnGitHub && (fullName == nil || confirmation.trimmingCharacters(in: .whitespaces) != fullName)))
            }
        }
        .padding(20)
        .frame(width: 580)
        .fixedSize(horizontal: false, vertical: true)
        .task(id: deleteOnGitHub) { await runChecks() }
    }

    private var buttonTitle: String {
        switch (deleteOnGitHub, deleteLocal) {
        case (true, true): "删除两者"
        case (true, false): "删除 GitHub 仓库"
        case (false, true): "移到废纸篓"
        case (false, false): "删除"
        }
    }

    @ViewBuilder
    private var remoteStatus: some View {
        if checking && remoteCheck == nil {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("正在检查 GitHub 上是否有本机还没下载的内容…").font(.caption).foregroundStyle(.secondary)
            }
        } else if let remoteCheckError {
            Label("无法检查 GitHub 上的内容：\(remoteCheckError)", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        } else if let count = remoteCheck?.remoteOnlyCommits, count > 0 {
            HStack {
                Label("GitHub 上有 \(count) 个提交本机还没下载（可能来自另一台 Mac），删除后它们只存在于那台电脑上。",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Spacer()
                Button("先同步") { syncFirst() }
            }
            .font(.caption)
        } else if remoteCheck != nil {
            Label("本机已包含 GitHub 上的全部内容。", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green)
        }
    }

    @ViewBuilder
    private var localStatus: some View {
        if let check = localCheck {
            if check.hasLocalOnlyWork {
                HStack {
                    Label(localWarning(check), systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Spacer()
                    if !deleteOnGitHub { Button("先同步") { syncFirst() } }
                }
                .font(.caption)
            } else {
                Label("所有内容都已上传到 GitHub。", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green)
            }
        }
    }

    private func localWarning(_ check: DeletionCheck) -> String {
        var parts: [String] = []
        if check.uncommittedFiles > 0 { parts.append("\(check.uncommittedFiles) 个文件的修改还没同步") }
        if check.unpushedCommits > 0 { parts.append("\(check.unpushedCommits) 个提交还没上传") }
        let tail = deleteOnGitHub ? "，GitHub 仓库也将删除，这些内容只会留在废纸篓里。" : "，建议先同步再删除。"
        return parts.joined(separator: "，") + tail
    }

    private func runChecks() async {
        checking = true
        defer { checking = false }
        do {
            localCheck = try await model.deletionCheck(repoID, includeRemote: false)
        } catch {
            localCheck = nil
        }
        guard deleteOnGitHub, remoteCheck == nil else { return }
        do {
            remoteCheck = try await model.deletionCheck(repoID, includeRemote: true)
            remoteCheckError = nil
        } catch {
            remoteCheckError = (error as? SyncFailure)?.message ?? error.localizedDescription
        }
    }

    private func syncFirst() {
        model.sync(repoID, trigger: .manualSingle)
        dismiss()
    }

    private func perform() async {
        working = true
        errorText = nil
        needsScope = false
        let outcome = await model.deleteRepository(repoID, onGitHub: deleteOnGitHub, local: deleteLocal)
        working = false
        switch outcome {
        case .done: dismiss()
        case .failed(let message): errorText = message
        case .needsDeleteScope: needsScope = true
        }
    }
}
