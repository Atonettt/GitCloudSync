import SwiftUI

/// The account's repositories on GitHub, including ones with no folder on this Mac: download one
/// as a synced folder, open it on GitHub, or delete one that is no longer needed.
struct DownloadFromGitHubView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var repositories: [GitHubRepositorySummary] = []
    @State private var loadError: String?
    @State private var loading = true
    @State private var search = ""
    @State private var selection: GitHubRepositorySummary.ID?
    @State private var parentFolder: URL?
    @State private var autoSync = true
    @State private var downloading = false
    @State private var downloadError: String?
    @State private var deleting: GitHubRepositorySummary?

    private var filtered: [GitHubRepositorySummary] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return repositories }
        return repositories.filter {
            $0.fullName.localizedCaseInsensitiveContains(query)
                || ($0.description?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private var selected: GitHubRepositorySummary? {
        repositories.first { $0.id == selection }
    }

    private var destination: URL? {
        guard let selected else { return nil }
        return (parentFolder ?? model.defaultDownloadFolder).appendingPathComponent(selected.name, isDirectory: true)
    }

    /// Why the selected repository can't be downloaded where chosen, if it can't.
    private var problem: String? {
        guard let selected, let destination else { return nil }
        if let existing = model.existingRepository(for: selected) {
            return String(localized: "已经在列表中：「\(existing.displayName)」")
        }
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: destination.path),
           !entries.filter({ $0 != ".DS_Store" }).isEmpty {
            return String(localized: "「\(destination.path)」已存在且不是空的，请换一个位置。")
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "icloud.and.arrow.down").font(.title).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("GitHub 上的仓库").font(.title3.bold())
                    Text("下载到这台 Mac 开始同步，或删除不再需要的仓库。")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            TextField("搜索", text: $search, prompt: Text("搜索仓库名或简介"))
                .textFieldStyle(.roundedBorder)

            list
                .frame(maxHeight: .infinity)
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))

            location

            if let message = problem ?? downloadError {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }

            HStack {
                Button {
                    if let selected { NSWorkspace.shared.open(selected.htmlURL) }
                } label: {
                    Label("在 GitHub 打开", systemImage: "safari")
                }
                .disabled(selected == nil)
                Button(role: .destructive) {
                    deleting = selected
                } label: {
                    Label("删除…", systemImage: "trash")
                }
                .disabled(selected == nil || selected.map { model.existingRepository(for: $0) != nil } == true || downloading)
                .help("永久删除 GitHub 上的这个仓库（列表中的仓库请在仓库页的「更多」里删除）")
                Spacer()
                Toggle("下载后开启自动同步", isOn: $autoSync)
                if downloading {
                    ProgressView().controlSize(.small)
                    Text("正在下载…").font(.callout).foregroundStyle(.secondary)
                }
                Button("完成") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(downloading)
                Button("下载") { download() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected == nil || problem != nil || downloading)
            }
        }
        .padding(20)
        .frame(width: 600, height: 580)
        .task { await load() }
        .onChange(of: selection) { downloadError = nil }
        .sheet(item: $deleting) { repository in
            DeleteGitHubRepositoryView(repository: repository) {
                repositories.removeAll { $0.id == repository.id }
                selection = nil
            }
        }
    }

    @ViewBuilder
    private var list: some View {
        if loading {
            ProgressView("正在读取 GitHub 上的仓库…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError {
            VStack(spacing: 8) {
                Text(loadError).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("重试") { Task { await load() } }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filtered.isEmpty {
            Text(repositories.isEmpty ? "这个账号在 GitHub 上还没有仓库" : "没有匹配的仓库")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(filtered, selection: $selection) { repository in
                row(repository).tag(repository.id)
            }
            .scrollContentBackground(.hidden)
            .contextMenu(forSelectionType: GitHubRepositorySummary.ID.self) { ids in
                if let repository = repositories.first(where: { $0.id == ids.first }) {
                    let listed = model.existingRepository(for: repository) != nil
                    Button("下载到这台 Mac") { selection = repository.id; download() }
                        .disabled(listed || downloading)
                    Button("在 GitHub 打开") { NSWorkspace.shared.open(repository.htmlURL) }
                    Divider()
                    Button("删除…", role: .destructive) { deleting = repository }
                        .disabled(listed || downloading)
                }
            }
        }
    }

    private func row(_ repository: GitHubRepositorySummary) -> some View {
        let existing = model.existingRepository(for: repository)
        return HStack(spacing: 10) {
            Image(systemName: repository.isPrivate ? "lock" : "globe")
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .help(repository.isPrivate ? String(localized: "私有仓库") : String(localized: "公开仓库"))
            VStack(alignment: .leading, spacing: 2) {
                Text(repository.fullName).lineLimit(1)
                Text(detail(for: repository)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if existing != nil {
                Text("已在列表中").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("不在本机").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .opacity(existing == nil ? 1 : 0.55)
    }

    private func detail(for repository: GitHubRepositorySummary) -> String {
        var parts: [String] = []
        if let pushed = repository.pushedAt {
            parts.append(String(localized: "\(pushed.formatted(.relative(presentation: .named)))更新"))
        }
        parts.append(ByteCountFormatter.string(fromByteCount: Int64(repository.size) * 1024, countStyle: .file))
        if repository.isArchived { parts.append(String(localized: "已归档")) }
        if let description = repository.description, !description.isEmpty { parts.append(description) }
        return parts.joined(separator: " · ")
    }

    private var location: some View {
        HStack(spacing: 8) {
            Text("下载到").foregroundStyle(.secondary)
            Text(destination?.path ?? (parentFolder ?? model.defaultDownloadFolder).path + "/…")
                .lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("更改…") { chooseParent() }
                .disabled(downloading)
        }
        .font(.callout)
    }

    private func load() async {
        loading = true
        loadError = nil
        do {
            repositories = try await model.gitHubRepositories()
        } catch {
            loadError = String(localized: "无法读取 GitHub 上的仓库：\(error.localizedDescription)")
        }
        loading = false
    }

    private func chooseParent() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "选择下载位置")
        panel.message = String(localized: "仓库会下载到这里的一个同名文件夹中")
        panel.prompt = String(localized: "选择")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = parentFolder ?? model.defaultDownloadFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        parentFolder = url
    }

    private func download() {
        guard let selected, let destination, problem == nil else { return }
        downloading = true
        downloadError = nil
        Task {
            let error = await model.downloadFromGitHub(selected, to: destination, autoSync: autoSync)
            downloading = false
            if let error { downloadError = error } else { dismiss() }
        }
    }
}

/// Confirms permanently deleting a GitHub repository that has no folder on this Mac.
private struct DeleteGitHubRepositoryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let repository: GitHubRepositorySummary
    let onDeleted: () -> Void

    @State private var working = false
    @State private var needsScope = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "trash").font(.title).foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 4) {
                    Text("永久删除 GitHub 上的「\(repository.fullName)」？").font(.title3.bold())
                    Text("仓库里的所有文件和历史版本都会被删除，无法恢复。这台 Mac 上没有它的文件夹，删除后就再也找不回来了；如果还想保留，请先下载到这台 Mac。")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if needsScope {
                VStack(alignment: .leading, spacing: 6) {
                    Label("GitHub 拒绝了删除：当前登录的令牌没有删除仓库的权限（delete_repo）。", systemImage: "person.badge.key.fill")
                        .foregroundStyle(.orange)
                    Text("使用 GitHub CLI 登录时，在终端执行下面的命令授权一次，然后回到这里再点删除。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text(DeleteRepositoryView.scopeCommand).font(.callout.monospaced()).textSelection(.enabled)
                        Button("复制") { Clipboard.copy(DeleteRepositoryView.scopeCommand) }
                    }
                }
                .font(.callout)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(working)
                Button("永久删除", role: .destructive) { delete() }
                    .disabled(working)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func delete() {
        working = true
        error = nil
        needsScope = false
        Task {
            switch await model.deleteGitHubRepository(repository) {
            case .done:
                onDeleted()
                dismiss()
            case .needsDeleteScope:
                needsScope = true
            case .failed(let message):
                error = message
            }
            working = false
        }
    }
}
