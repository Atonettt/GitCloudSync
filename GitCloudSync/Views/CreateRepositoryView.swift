import SwiftUI

/// Turns a plain folder into a new GitHub repository named after it.
struct CreateRepositoryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    let folder: URL

    @State private var name = ""
    @State private var isPrivate = true
    @State private var description = ""
    @State private var preview: FolderPreview?
    @State private var previewError: String?
    @State private var working = false
    @State private var errorText: String?
    @State private var existingEmpty: String?

    var body: some View {
        let login = model.auth.user?.login
        let canCreate = model.auth.state.isUsable && login != nil
        let nameProblem = RepositoryNaming.problem(with: name)

        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "folder.badge.plus").font(.title).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("在 GitHub 上创建仓库").font(.title3.bold())
                    Text(folder.path).font(.callout).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
            }

            folderSummary

            Form {
                TextField("仓库名", text: $name, prompt: Text(String(localized: "例如 research-notes")))
                    .onChange(of: name) { existingEmpty = nil }
                if !name.isEmpty, let nameProblem {
                    Text(nameProblem).font(.caption).foregroundStyle(.red)
                } else if let login, !name.isEmpty {
                    Text("将创建 github.com/\(login)/\(name)，本地文件夹名保持「\(folder.lastPathComponent)」不变。")
                        .font(.caption).foregroundStyle(.secondary)
                } else if name.isEmpty {
                    Text("GitHub 仓库名只能用英文字母、数字、-、_ 和 .，请起一个英文名。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("私有仓库（只有你能看到）", isOn: $isPrivate)
                TextField("描述（可选）", text: $description)
            }
            .formStyle(.grouped)
            .disabled(working)

            if !canCreate {
                HStack {
                    Label("需要先登录 GitHub 才能自动创建仓库", systemImage: "person.badge.key.fill").foregroundStyle(.orange)
                    Spacer()
                    Button("打开设置") { openSettings() }
                }
                .font(.callout)
            }

            if let existingEmpty {
                HStack(alignment: .top) {
                    Label("GitHub 上已有一个空的「\(existingEmpty)」仓库。可以直接关联它，不再新建。", systemImage: "link")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("关联这个仓库") { Task { await create(linkExisting: true) } }
                        .disabled(working)
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
                    Text("正在创建…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(working)
                Button("创建并同步") { Task { await create(linkExisting: false) } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || !canCreate || nameProblem != nil || preview == nil || isBlocked)
            }
        }
        .padding(20)
        .frame(width: 560, height: 540)
        .task {
            name = RepositoryNaming.suggestedName(for: folder.lastPathComponent)
            do {
                preview = try await model.previewFolder(folder)
            } catch {
                previewError = (error as? SyncFailure)?.message ?? error.localizedDescription
            }
        }
    }

    private var isBlocked: Bool {
        if case .insideRepository = preview?.kind { return true }
        if case .linkedRepository = preview?.kind { return true }
        return false
    }

    @ViewBuilder
    private var folderSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let preview {
                switch preview.kind {
                case .plainFolder:
                    Label("普通文件夹：将初始化 Git，并把全部文件作为第一次同步上传。", systemImage: "folder")
                case .repositoryWithoutRemote(let commits):
                    Label("已经是 Git 仓库（\(commits) 个提交），还没有关联 GitHub：将创建仓库并上传现有历史。", systemImage: "externaldrive.badge.icloud")
                case .linkedRepository(let remote):
                    Label("这个文件夹已经关联了 \(remote)，请直接用「添加仓库」。", systemImage: "link").foregroundStyle(.orange)
                case .insideRepository(let root):
                    Label("这个文件夹位于仓库「\(root)」里面，已经随它一起同步，不能再单独创建仓库。", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                Label(String(localized: "约 \(preview.fileCount) 个文件，共 \(ByteCountFormatter.string(fromByteCount: preview.totalBytes, countStyle: .file))")
                      + (preview.truncated ? String(localized: "（文件太多，只统计了一部分）") : "")
                      + String(localized: "，不含 .DS_Store、Office 临时文件等忽略的文件。"),
                      systemImage: "doc.on.doc")
                    .foregroundStyle(.secondary)
                if !preview.oversized.isEmpty {
                    Label(String(localized: "\(preview.oversized.count) 个文件超过上传上限，会留在本地、不上传：")
                          + preview.oversized.prefix(3).map { $0.path }.joined(separator: String(localized: "、"))
                          + (preview.oversized.count > 3 ? String(localized: " 等") : ""),
                          systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                }
                if preview.isInICloud {
                    Label("这个文件夹同时由 iCloud 云盘同步。iCloud 可能把文件移到云端或生成冲突副本，影响 Git；建议放到不经过 iCloud 的位置，例如个人文件夹下的 GitSync 文件夹。",
                          systemImage: "icloud")
                        .foregroundStyle(.orange)
                }
            } else if let previewError {
                Label(previewError, systemImage: "xmark.octagon").foregroundStyle(.red)
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在检查文件夹…").foregroundStyle(.secondary)
                }
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func create(linkExisting: Bool) async {
        working = true
        errorText = nil
        let outcome = await model.createGitHubRepository(folder: folder, name: name, isPrivate: isPrivate,
                                                         description: description, linkExisting: linkExisting)
        working = false
        switch outcome {
        case .created:
            dismiss()
        case .failed(let message):
            errorText = message
        case .nameTakenButEmpty(let fullName):
            existingEmpty = fullName
        }
    }
}
