import SwiftUI

private func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

/// One line on the repository card: "文件 35 MB · 历史 16 MB".
struct UsageSummaryView: View {
    @Environment(AppModel.self) private var model
    let repoID: UUID

    var body: some View {
        let runtime = model.runtime[repoID]
        HStack(spacing: 8) {
            if let usage = runtime?.usage {
                Text("文件 \(formatBytes(usage.fileBytes)) · 历史 \(formatBytes(usage.historyBytes))")
                switch usage.level {
                case .normal:
                    EmptyView()
                case .large:
                    Label("超过 GitHub 建议的 1 GB", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                case .veryLarge:
                    Label("超过 5 GB", systemImage: "exclamationmark.octagon.fill").foregroundStyle(.red)
                }
                Button("详情") { model.activeSheet = .storage(repoID) }
                    .buttonStyle(.link)
            } else if runtime?.measuringUsage == true {
                Text("正在计算…").foregroundStyle(.secondary)
            } else {
                Text("—").foregroundStyle(.secondary)
            }
        }
    }
}

/// Where the space goes: totals against GitHub's limits and the files that take the most history.
struct StorageView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let repoID: UUID

    @State private var files: [HistoryFileUsage] = []
    @State private var loadingFiles = true
    @State private var errorText: String?

    var body: some View {
        let repo = model.repository(repoID)
        let runtime = model.runtime[repoID]
        let usage = runtime?.usage

        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                Image(systemName: "internaldrive").font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("空间占用 — \(repo?.displayName ?? "")").font(.title3.bold())
                    Text(usage.map { String(localized: "统计于 \($0.measuredAt.formatted(date: .omitted, time: .shortened))") } ?? String(localized: "正在统计…"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("重新统计") { Task { await reload(force: true) } }
                    .disabled(runtime?.measuringUsage == true || loadingFiles)
            }

            if let usage {
                HStack(spacing: 12) {
                    metric(String(localized: "当前文件"), usage.fileBytes, note: String(localized: "文件夹里现在的文件"))
                    metric(String(localized: "历史"), usage.historyBytes, note: String(localized: "每次同步保存的所有版本（.git）"))
                }
                limitBar(usage)
            }

            Text("历史保存了每次同步时的版本。纯文本只多存改动的部分；Word、PPT、PDF、图片、视频这类文件每修改一次，历史里大约就多存一整份。删除文件也不会让历史变小，旧版本仍然保留，可以在「历史版本」里找回。")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("历史中最占空间的文件").font(.headline)
            List(files) { file in
                let exists = repo.map { FileManager.default.fileExists(atPath: URL(fileURLWithPath: $0.path).appendingPathComponent(file.path).path) } ?? false
                HStack(spacing: 10) {
                    Image(systemName: exists ? "doc" : "trash").foregroundStyle(.secondary).frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.path).lineLimit(1).truncationMode(.middle)
                        Text(String(localized: "\(file.versions) 个版本 · 最大一版 \(formatBytes(file.largestVersionBytes))") + (exists ? "" : String(localized: " · 已删除，旧版本仍在历史中")))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(formatBytes(file.storedBytes)).font(.callout.monospacedDigit().weight(.medium))
                    if exists {
                        Button { model.revealInFinder(repoID, relativePath: file.path) } label: { Image(systemName: "folder") }
                            .buttonStyle(.borderless)
                            .help("在 Finder 中显示")
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 200)
            .overlay {
                if loadingFiles { ProgressView() }
                else if let errorText { Text(errorText).foregroundStyle(.red).padding() }
                else if files.isEmpty { Text("还没有历史").foregroundStyle(.secondary) }
            }

            if let usage, usage.level != .normal {
                Label("仓库已经比较大。经常修改的大文件（视频、大型 PPT、安装包等）建议移出这个文件夹，放到不同步的位置，可以减缓历史继续增长。",
                      systemImage: "lightbulb")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640, height: 600)
        .task { await reload(force: false) }
    }

    private func metric(_ title: String, _ bytes: Int64, note: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(formatBytes(bytes)).font(.title2.bold().monospacedDigit())
            Text(note).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    /// History size on a 0–5 GB scale with GitHub's 1 GB recommendation marked.
    private func limitBar(_ usage: RepositoryUsage) -> some View {
        let scale = Double(RepositoryUsage.veryLargeThreshold)
        let fraction = min(Double(usage.historyBytes) / scale, 1)
        let color: Color = switch usage.level {
        case .normal: .green
        case .large: .orange
        case .veryLarge: .red
        }
        return VStack(alignment: .leading, spacing: 4) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule().fill(color).frame(width: max(4, proxy.size.width * fraction))
                    Rectangle().fill(Color.secondary).frame(width: 1.5, height: 14)
                        .offset(x: proxy.size.width * Double(RepositoryUsage.largeThreshold) / scale)
                }
            }
            .frame(height: 10)
            HStack {
                Text("0")
                Spacer()
                Text("GitHub 建议 1 GB 以内，超过 5 GB 会收到警告，单次上传不能超过 2 GB")
                Spacer()
                Text("5 GB")
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func reload(force: Bool) async {
        loadingFiles = true
        errorText = nil
        defer { loadingFiles = false }
        await model.refreshUsage(repoID, force: force)
        guard let repo = model.repository(repoID), let git = model.gitEnvironment else { return }
        let scanner = RepositoryUsageScanner(client: GitClient(repositoryURL: URL(fileURLWithPath: repo.path), git: git))
        do {
            files = try await scanner.largestFiles()
        } catch {
            errorText = (error as? SyncFailure)?.message ?? error.localizedDescription
        }
    }
}
