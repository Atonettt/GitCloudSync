import SwiftUI

/// The repository folder as it is on disk: browse it like Finder, see which files aren't synced
/// yet, and preview the selected file.
struct RepositoryFilesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let repo: RepositoryConfig

    struct Item: Identifiable, Hashable {
        let name: String
        /// Relative to the repository folder.
        let path: String
        let isDirectory: Bool
        let size: Int64?
        let modified: Date?
        var id: String { path }
    }

    @State private var folder = ""
    @State private var items: [Item] = []
    @State private var selection: Item.ID?
    @State private var unsynced: Set<String> = []
    @State private var loading = false

    private var root: URL { URL(fileURLWithPath: repo.path) }

    var body: some View {
        HStack(spacing: 0) {
            browser
                .frame(width: 260)
                .frame(maxHeight: .infinity)
            Divider()
            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: folder) { await reload() }
        // Clicking a folder goes into it, like a sidebar; files are previewed on the right.
        .onChange(of: selection) { _, id in
            if let item = item(id), item.isDirectory { folder = item.path }
        }
        .onChange(of: model.runtime[repo.id]?.isSyncing) { _, syncing in
            if syncing == false { Task { await reload() } }
        }
    }

    // MARK: Browser

    private var browser: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                if !folder.isEmpty {
                    Button {
                        folder = (folder as NSString).deletingLastPathComponent
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.borderless)
                    .help("返回上一级")
                }
                ScrollView(.horizontal, showsIndicators: false) { breadcrumb }
                Button {
                    Task { await reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("刷新")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            List(items, selection: $selection) { item in
                row(item).tag(item.id)
            }
            .contextMenu(forSelectionType: Item.ID.self) { ids in
                if let item = item(ids.first) {
                    Button(item.isDirectory ? String(localized: "打开文件夹") : String(localized: "打开")) { open(item) }
                    Button("在 Finder 中显示") { reveal(item) }
                    if !item.isDirectory {
                        Button("历史版本") { showHistory(item) }
                    }
                }
            } primaryAction: { ids in
                if let item = item(ids.first) { open(item) }
            }
            .overlay {
                if !loading, items.isEmpty {
                    Text("这个文件夹是空的").foregroundStyle(.secondary)
                }
            }
        }
    }

    private var breadcrumb: some View {
        let parts = folder.split(separator: "/").map(String.init)
        return HStack(spacing: 2) {
            Button(repo.displayName) { folder = "" }
                .buttonStyle(.borderless)
                .fontWeight(parts.isEmpty ? .semibold : .regular)
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                Button(part) { folder = parts[...index].joined(separator: "/") }
                    .buttonStyle(.borderless)
                    .fontWeight(index == parts.count - 1 ? .semibold : .regular)
            }
        }
        .font(.callout)
        .foregroundStyle(.primary)
    }

    private func row(_ item: Item) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: FileIcons.icon(for: url(item), isDirectory: item.isDirectory))
                .resizable()
                .frame(width: 18, height: 18)
            Text(item.name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if let badge = badge(for: item) {
                Text(badge.text)
                    .font(.caption2)
                    .foregroundStyle(badge.color)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(badge.color.opacity(0.12), in: Capsule())
            }
            if !item.isDirectory, let size = item.size {
                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.vertical, 1)
    }

    /// Why a file isn't (or isn't yet) on GitHub, if that's the case.
    private func badge(for item: Item) -> (text: String, color: Color)? {
        if RepositoryCreator.isIgnored(item.name, patterns: model.settings.ignorePatterns) {
            return (String(localized: "不同步"), .secondary)
        }
        if !item.isDirectory, let size = item.size, size > Int64(max(1, model.settings.largeFileLimitMB)) * 1024 * 1024 {
            return (String(localized: "超过上限"), .orange)
        }
        let pending = item.isDirectory
            ? unsynced.contains { $0.hasPrefix(item.path + "/") }
            : unsynced.contains(item.path)
        return pending ? (String(localized: "未同步"), .orange) : nil
    }

    // MARK: Preview

    @ViewBuilder
    private var preview: some View {
        if let item = item(selection) {
            VStack(spacing: 0) {
                previewHeader(item)
                Divider()
                if item.isDirectory {
                    let count = (try? FileManager.default.contentsOfDirectory(
                        at: url(item), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
                    ).count) ?? 0
                    ContentUnavailableView {
                        Label(item.name, systemImage: "folder")
                    } description: {
                        Text("里面有 \(count) 项")
                    } actions: {
                        Button("打开文件夹") { open(item) }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    QuickLookView(url: url(item)).id(item.id)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        } else {
            ContentUnavailableView {
                Label(folder.isEmpty ? repo.displayName : (folder as NSString).lastPathComponent, systemImage: "folder")
            } description: {
                Text(items.isEmpty ? String(localized: "这个文件夹是空的") : String(localized: "里面有 \(items.count) 项，点左边的文件即可预览。"))
            }
        }
    }

    private func previewHeader(_ item: Item) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: FileIcons.icon(for: url(item), isDirectory: item.isDirectory))
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.headline).lineLimit(1).truncationMode(.middle)
                Text(details(item)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func details(_ item: Item) -> String {
        var parts: [String] = []
        if let size = item.size, !item.isDirectory {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        if let modified = item.modified {
            parts.append(String(localized: "修改于 \(modified.formatted(date: .abbreviated, time: .shortened))"))
        }
        if let badge = badge(for: item) {
            parts.append(badge.text)
        } else if !item.isDirectory {
            parts.append(String(localized: "已同步"))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Actions

    private func item(_ id: Item.ID?) -> Item? {
        id.flatMap { id in items.first { $0.id == id } }
    }

    private func url(_ item: Item) -> URL {
        root.appendingPathComponent(item.path)
    }

    private func open(_ item: Item) {
        if item.isDirectory {
            folder = item.path
        } else {
            NSWorkspace.shared.open(url(item))
        }
    }

    private func reveal(_ item: Item) {
        NSWorkspace.shared.activateFileViewerSelecting([url(item)])
    }

    private func showHistory(_ item: Item) {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: WindowID.history, value: HistoryRequest(repoID: repo.id, path: item.path))
    }

    private func reload() async {
        loading = true
        defer { loading = false }
        let directory = folder.isEmpty ? root : root.appendingPathComponent(folder)
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else {
            // The folder went away (deleted or moved): go back to the top.
            if !folder.isEmpty { folder = "" }
            items = []
            return
        }
        let prefix = folder.isEmpty ? "" : folder + "/"
        items = contents.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isDirectory = values?.isDirectory == true
            return Item(
                name: url.lastPathComponent,
                path: prefix + url.lastPathComponent,
                isDirectory: isDirectory,
                size: isDirectory ? nil : values?.fileSize.map(Int64.init),
                modified: values?.contentModificationDate
            )
        }
        .sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        // Show something right away: keep the selection if it's still here, otherwise preview the first file.
        if item(selection) == nil || item(selection)?.isDirectory == true {
            selection = items.first { !$0.isDirectory }?.id
        }
        unsynced = await model.unsyncedPaths(repo.id)
    }
}

/// File-type icons, fetched once per kind of file instead of on every redraw. NSCache gives them
/// back to the system when memory gets tight.
@MainActor
private enum FileIcons {
    static let cache = NSCache<NSString, NSImage>()

    static func icon(for url: URL, isDirectory: Bool) -> NSImage {
        let key = (isDirectory ? "folder." : "file.") + url.pathExtension.lowercased()
        if let cached = cache.object(forKey: key as NSString) { return cached }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(image, forKey: key as NSString)
        return image
    }
}
