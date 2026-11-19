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
    /// What the latest sync changed (path → "A" new / "M" modified) and when it ran.
    @State private var recent: [String: Character] = [:]
    @State private var recentDate: Date?
    @State private var loading = false
    @State private var revertTarget: Item?
    /// Show what changed instead of the file: unsynced edits against the last synced version, or
    /// for a synced file its latest change against the version before.
    @AppStorage("files.compare") private var comparing = false
    /// Width of the file list, set by dragging the bar between the list and the preview.
    @AppStorage("files.listWidth") private var listWidth = RepositoryFilesView.defaultListWidth
    /// How far the bar has moved during the current drag.
    @State private var dragOffset: CGFloat = 0
    /// The file list is hidden after being dragged all the way left; drag the bar back out to show it.
    @AppStorage("files.listCollapsed") private var listCollapsed = false
    static let defaultListWidth: Double = 260
    /// Dragging the list narrower than this hides it completely.
    static let collapseBelow: CGFloat = 110
    static let minListWidth: CGFloat = 200
    static let minPreviewWidth: CGFloat = 320
    @State private var baseline: Baseline?
    /// The version to compare with: nil means automatic (last sync for unsynced edits, otherwise the
    /// sync point before); otherwise a `FileVersion.id` the user picked.
    @State private var baseChoice: String?
    /// Every synced version of the selected file, offered in the "对比对象" menu.
    @State private var fileVersions: [FileVersion] = []
    /// Which file `fileVersions` belongs to.
    @State private var versionsPath: String?

    private struct Baseline {
        let path: String
        let modified: Date?
        let choice: String?
        let url: URL?
        let caption: String
        /// Set when the chosen version could not be loaded.
        var error: String?
    }

    private func comparisonKey(_ item: Item) -> String {
        // Includes whether Git is ready: right after launch it isn't yet, and the comparison must
        // run again once it is instead of spinning forever.
        "\(item.id)|\(item.modified?.timeIntervalSince1970 ?? 0)|\(baseChoice ?? "auto")|\(model.gitEnvironment != nil)"
    }

    private var root: URL { URL(fileURLWithPath: repo.path) }

    var body: some View {
        GeometryReader { proxy in
            // The file list may take at most what leaves the preview a usable width.
            let maxList = max(Self.minListWidth, proxy.size.width - Self.minPreviewWidth - 12)
            let width = shownListWidth(raw: (listCollapsed ? 0 : listWidth) + dragOffset, max: maxList)
            HStack(spacing: 0) {
                if width > 0 {
                    browser
                        .frame(width: width)
                        .frame(maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .glassPanel(cornerRadius: 16)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                PaneResizeHandle(
                    onDrag: { dragOffset = $0 },
                    onEnd: { translation in
                        let raw = (listCollapsed ? 0 : listWidth) + translation
                        withAnimation(.easeOut(duration: 0.18)) {
                            if raw < Self.collapseBelow {
                                listCollapsed = true
                            } else {
                                listCollapsed = false
                                listWidth = min(max(raw, Self.minListWidth), maxList)
                            }
                            dragOffset = 0
                        }
                    },
                    onReset: {
                        withAnimation(.easeOut(duration: 0.18)) {
                            if listCollapsed { listCollapsed = false } else { listWidth = Self.defaultListWidth }
                        }
                    }
                )
                preview
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .glassPanel(cornerRadius: 16)
            }
        }
        // No refresh button: the list follows the folder by itself — files added, removed or renamed
        // here (in Finder or another app), every finished sync, and coming back to the app.
        .task(id: folder) {
            await reload()
            let directory = folder.isEmpty ? root : root.appendingPathComponent(folder)
            for await _ in FolderChanges.stream(for: directory) {
                await reload()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await reload() }
        }
        // Clicking a folder goes into it, like a sidebar; files are previewed on the right.
        .onChange(of: selection) { _, id in
            baseChoice = nil
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
                    .hoverHighlight()
                    .help("返回上一级")
                }
                ScrollView(.horizontal, showsIndicators: false) { breadcrumb }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            List(items, selection: $selection) { item in
                row(item).hoverRow().tag(item.id)
            }
            .scrollContentBackground(.hidden)
            .progressiveBlurEdges(top: 10, bottom: 18)
            .contextMenu(forSelectionType: Item.ID.self) { ids in
                if let item = item(ids.first) {
                    Button(item.isDirectory ? String(localized: "打开文件夹") : String(localized: "打开")) { open(item) }
                    Button("在 Finder 中显示") { reveal(item) }
                    if !item.isDirectory {
                        Button("历史版本") { showHistory(item) }
                    }
                    if isPending(item) {
                        Divider()
                        Button("还原为云端版本…") { revertTarget = item }
                    }
                }
            } primaryAction: { ids in
                if let item = item(ids.first) { open(item) }
            }
            .confirmationDialog(
                String(localized: "将「\(revertTarget?.name ?? "")」还原为 GitHub 上的版本？"),
                isPresented: Binding(get: { revertTarget != nil }, set: { if !$0 { revertTarget = nil } }),
                presenting: revertTarget
            ) { item in
                Button("还原", role: .destructive) { model.revertToCloud(repo.id, paths: [item.path]) }
            } message: { item in
                Text(item.isDirectory
                     ? "这个文件夹里还没同步的修改会被丢弃，换回 GitHub 上现在的内容。只在本机的新文件不受影响；丢弃的内容会在本机保留一份备份。"
                     : "这个文件还没同步的修改会被丢弃，换回 GitHub 上现在的内容。丢弃的内容会在本机保留一份备份。")
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
                .hoverHighlight()
                .fontWeight(parts.isEmpty ? .semibold : .regular)
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                Button(part) { folder = parts[...index].joined(separator: "/") }
                    .buttonStyle(.borderless)
                    .hoverHighlight()
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
                    .help(badgeHelp(for: item))
            } else if item.isDirectory, recent.keys.contains(where: { $0.hasPrefix(item.path + "/") }) {
                Circle().fill(Color.blue).frame(width: 7, height: 7)
                    .help(String(localized: "里面有文件在上一次同步时改动过"))
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
        if isPending(item) { return (String(localized: "未同步"), .orange) }
        guard !item.isDirectory else { return nil }
        switch recent[item.path] {
        case "A": return (String(localized: "新增"), .green)
        case "M": return (String(localized: "已修改"), .blue)
        default: return nil
        }
    }

    private func badgeHelp(for item: Item) -> String {
        guard !isPending(item), !item.isDirectory, recent[item.path] != nil else { return "" }
        let when = recentDate?.formatted(date: .abbreviated, time: .shortened) ?? ""
        return String(localized: "上一次同步（\(when)）时改动，切到「对比改动」可以看具体改了什么")
    }

    private func isPending(_ item: Item) -> Bool {
        item.isDirectory ? unsynced.contains { $0.hasPrefix(item.path + "/") } : unsynced.contains(item.path)
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
                    VStack(spacing: 16) {
                        GlassFolderView(directory: url(item), title: item.name, count: count)
                            .frame(height: 260)
                        Button("打开文件夹") { open(item) }
                            .glassButton(prominent: true)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if comparing {
                    if let baseline, baseline.path == item.path, baseline.modified == item.modified,
                       baseline.choice == baseChoice {
                        if let error = baseline.error {
                            ContentUnavailableView {
                                Label("无法对比", systemImage: "exclamationmark.triangle")
                            } description: {
                                Text(error)
                            } actions: {
                                Button("重试") { self.baseline = nil }
                            }
                        } else {
                            VersionComparisonView(old: baseline.url, new: url(item),
                                                  kind: (item.name as NSString).pathExtension,
                                                  caption: baseline.caption)
                                .id(comparisonKey(item))
                        }
                    } else {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                            .task(id: comparisonKey(item)) { await loadBaseline(item) }
                    }
                } else {
                    QuickLookView(url: url(item), revision: item.modified).id(item.id)
                        .progressiveBlurEdges(top: 12, bottom: 22)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        } else {
            VStack(spacing: 10) {
                GlassFolderView(directory: folder.isEmpty ? root : root.appendingPathComponent(folder),
                                title: folder.isEmpty ? repo.displayName : (folder as NSString).lastPathComponent,
                                count: items.count)
                    .frame(height: 260)
                    .id(folder)
                Text(items.isEmpty ? String(localized: "这个文件夹是空的") : String(localized: "点左边的文件即可预览"))
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// While dragging: below the collapse point the list disappears, otherwise it snaps to its limits.
    private func shownListWidth(raw: CGFloat, max maxList: CGFloat) -> CGFloat {
        if raw < Self.collapseBelow { return 0 }
        return min(Swift.max(raw, Self.minListWidth), maxList)
    }

    /// One row when the pane is wide; when narrow, the "预览 / 对比改动" switch moves under the name
    /// so the file name isn't squeezed down to a few letters.
    private func previewHeader(_ item: Item) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                previewTitle(item).frame(minWidth: 200, alignment: .leading)
                Spacer(minLength: 0)
                if !item.isDirectory { headerControls(item) }
            }
            VStack(alignment: .leading, spacing: 10) {
                previewTitle(item)
                if !item.isDirectory { headerControls(item) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func previewTitle(_ item: Item) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: FileIcons.icon(for: url(item), isDirectory: item.isDirectory))
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.headline).lineLimit(1).truncationMode(.middle)
                Text(details(item)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private func modePicker(_ item: Item) -> some View {
        Picker("显示", selection: $comparing) {
            Text("预览").tag(false)
            Text("对比改动").tag(true)
        }
        .pickerStyle(.segmented)
        .hoverControl()
        .labelsHidden()
        .fixedSize()
        .help(isPending(item)
              ? String(localized: "对比改动：标出你还没同步的修改")
              : String(localized: "对比改动：标出这个文件和上一个时间节点相比改了哪些地方"))
    }

    /// "对比对象 [自动 ▾]": compare the file on disk with any synced version of it.
    /// "预览 / 对比改动", and while comparing, the version to compare with right beside it.
    private func headerControls(_ item: Item) -> some View {
        HStack(spacing: 8) {
            modePicker(item)
            if comparing { basePicker(item) }
        }
    }

    private func basePicker(_ item: Item) -> some View {
        Picker("对比对象", selection: $baseChoice) {
            Text(isPending(item) ? String(localized: "上次同步的版本") : String(localized: "上一个时间节点"))
                .tag(String?.none)
            if !fileVersions.isEmpty {
                Divider()
                ForEach(fileVersions) { version in
                    Text(versionTitle(version)).tag(String?.some(version.id))
                }
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .hoverControl()
        // A menu picker is as wide as its longest item; long version titles would push the whole
        // window wider than it is. Cap it so the title truncates instead.
        // A fixed width: a menu picker is as wide as its title, and a width that changes with the title
        // would make the header switch between one and two rows (and long titles widen the window).
        .frame(width: 220, alignment: .leading)
        .help("对比对象：选择要和现在的文件对比的时间节点")
        .task(id: "\(item.path)|\(model.gitEnvironment != nil)") { await loadVersions(item) }
    }

    private func versionTitle(_ version: FileVersion) -> String {
        var parts = [HistoryFormat.relative(version.commit.date), version.commit.source]
        if version.id == fileVersions.first?.id { parts.append(String(localized: "最新同步版本")) }
        if version.path != item(selection)?.path {
            parts.append(String(localized: "当时名为「\(HistoryFormat.fileName(version.path))」"))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func loadVersions(_ item: Item) async {
        // Another file's versions would offer the wrong choices; the same file's stay until the new list
        // arrives, so the menu never goes blank while reloading.
        if versionsPath != item.path { fileVersions = [] }
        guard let browser = model.historyBrowser(repo.id) else { return }
        let loaded = ((try? await browser.versions(of: item.path)) ?? []).filter { !$0.isDeletion }
        guard !Task.isCancelled else { return }
        fileVersions = loaded
        versionsPath = item.path
        if let choice = baseChoice, !loaded.contains(where: { $0.id == choice }) { baseChoice = nil }
    }

    /// What the file is compared with. A picked version if there is one; otherwise, unsynced: the
    /// version at the last sync (what GitHub has); synced: the version before its latest change.
    private func loadBaseline(_ item: Item) async {
        guard let browser = model.historyBrowser(repo.id) else { return }
        let choice = baseChoice
        func done(_ url: URL?, _ caption: String, error: String? = nil) {
            guard !Task.isCancelled else { return }
            baseline = Baseline(path: item.path, modified: item.modified, choice: choice, url: url,
                                caption: caption, error: error)
        }
        if let choice {
            guard let version = fileVersions.first(where: { $0.id == choice }) else {
                baseChoice = nil
                return
            }
            do {
                let file = try await browser.exportForPreview(path: version.path, commit: version.commit.id,
                                                              date: version.commit.date)
                done(file, String(localized: "现在的文件与 \(HistoryFormat.relative(version.commit.date)) 的版本相比"))
            } catch {
                done(nil, "", error: HistoryFormat.describe(error))
            }
            return
        }
        if isPending(item) {
            if let file = try? await browser.exportForPreview(path: item.path, commit: "HEAD", date: Date()) {
                done(file, String(localized: "你还没同步的修改，与上次同步的版本（GitHub 上的版本）相比"))
            } else {
                done(nil, String(localized: "新文件，还没有同步过"))
            }
            return
        }
        // Synced: against the sync point before the last one, whether or not this file changed then.
        guard let point = try? await browser.previousSyncPoint(before: "HEAD", path: item.path) else {
            done(nil, String(localized: "这是最早的时间节点，之前没有版本"))
            return
        }
        let when = point.date.formatted(date: .abbreviated, time: .shortened)
        let file = point.hasFile
            ? try? await browser.exportForPreview(path: item.path, commit: point.commit, date: point.date) : nil
        done(file, String(localized: "与上一个时间节点（\(when)）相比"))
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
        model.historyRequest = HistoryRequest(repoID: repo.id, path: item.path)
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
        if let browser = model.historyBrowser(repo.id) {
            let last = await browser.lastSyncChanges()
            recent = last.changes
            recentDate = last.date
        }
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

/// Changes to the entries of one folder (added, removed, renamed or replaced files), delivered
/// at most a few times a second. Ends when the folder goes away or the consuming task is cancelled.
enum FolderChanges {
    static func stream(for directory: URL) -> AsyncStream<Void> {
        AsyncStream { continuation in
            let descriptor = open(directory.path, O_EVTONLY)
            guard descriptor >= 0 else {
                continuation.finish()
                return
            }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor, eventMask: [.write, .delete, .rename, .extend, .attrib],
                queue: .main)
            let pending = PendingFlag()
            source.setEventHandler {
                if source.data.contains(.delete) || source.data.contains(.rename) {
                    // The folder itself was removed or moved: the view goes back to the top.
                    continuation.yield()
                    continuation.finish()
                    return
                }
                // Coalesce bursts (a save writes several times) into one reload.
                guard !pending.value else { return }
                pending.value = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    pending.value = false
                    continuation.yield()
                }
            }
            source.setCancelHandler { close(descriptor) }
            continuation.onTermination = { _ in source.cancel() }
            source.resume()
        }
    }
}

/// Only touched on the main queue, where the folder events and the delayed reload both run.
private final class PendingFlag: @unchecked Sendable {
    var value = false
}

/// The bar between two panes: drag sideways to resize (all the way left hides the list), double-click
/// to bring it back or return to the default width.
/// It sits in the gap between the panels and shows a small grip, brighter while hovered or dragged.
struct PaneResizeHandle: View {
    let onDrag: (CGFloat) -> Void
    let onEnd: (CGFloat) -> Void
    let onReset: () -> Void

    @State private var hovering = false
    @State private var dragging = false

    var body: some View {
        ZStack {
            Color.clear
            Capsule()
                .fill(Color.primary.opacity(dragging ? 0.45 : hovering ? 0.30 : 0.14))
                .frame(width: 4, height: 44)
        }
        .frame(width: 12)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    dragging = true
                    onDrag(value.translation.width)
                }
                .onEnded { value in
                    dragging = false
                    onEnd(value.translation.width)
                }
        )
        .onTapGesture(count: 2) { onReset() }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.12), value: dragging)
        .help("拖动调整宽度，拉到最左可隐藏文件列表；双击恢复")
        .accessibilityLabel(Text("调整文件列表宽度"))
    }
}
