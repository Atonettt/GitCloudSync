import SwiftUI
import QuickLookThumbnailing

// Small visual pieces inspired by web component galleries (LeiBox, Magic UI), rebuilt natively:
// a frosted folder that fans out its files, a breathing dot-matrix loader, soft blurred edges on
// scrolling areas, and the ⌘K command bar.

// MARK: - Glass folder

/// A frosted folder with thumbnails of its first files peeking out; hovering fans them out.
struct GlassFolderView: View {
    let directory: URL
    let title: String
    let count: Int

    @State private var thumbnails: [NSImage] = []
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    private let width: CGFloat = 230
    private let height: CGFloat = 160

    var body: some View {
        VStack(spacing: 18) {
            ZStack(alignment: .bottom) {
                backPanel
                papers
                frontPanel
            }
            .frame(width: width, height: height + 50, alignment: .bottom)
            .scaleEffect(hovering ? 1.03 : 1)
            .animation(.spring(response: 0.45, dampingFraction: 0.7), value: hovering)
            .onHover { hovering = $0 }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: directory) { await loadThumbnails() }
    }

    private var backPanel: some View {
        FolderBackShape()
            .fill(LinearGradient(colors: [Color.accentColor.opacity(0.85), Color.accentColor.opacity(0.55)],
                                 startPoint: .top, endPoint: .bottom))
            .frame(width: width, height: height)
            .shadow(color: .black.opacity(0.18), radius: 18, y: 10)
    }

    private var papers: some View {
        let shown = Array(thumbnails.prefix(3))
        return ZStack {
            ForEach(Array(shown.enumerated()), id: \.offset) { index, image in
                let spread = CGFloat(index) - CGFloat(shown.count - 1) / 2
                paper(image)
                    .rotationEffect(.degrees(Double(spread) * (hovering ? 14 : 6)), anchor: .bottom)
                    .offset(x: spread * (hovering ? 46 : 18), y: hovering ? -62 : -30)
                    .zIndex(Double(index))
            }
            if shown.isEmpty {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.white.opacity(0.9))
                    .frame(width: 96, height: 116)
                    .offset(y: hovering ? -50 : -26)
            }
        }
        .frame(width: width, height: height, alignment: .bottom)
        .padding(.bottom, 24)
    }

    private func paper(_ image: NSImage) -> some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: 96, height: 120)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.black.opacity(0.08)))
            .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
    }

    private var frontPanel: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return VStack(alignment: .leading, spacing: 2) {
            Spacer()
            Text(title).font(.headline).lineLimit(1).truncationMode(.middle)
            Text(count == 0 ? String(localized: "空文件夹") : String(localized: "\(count) 项"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: width, height: height * 0.72, alignment: .leading)
        .background(.ultraThinMaterial, in: shape)
        .background(Color.white.opacity(scheme == .dark ? 0.04 : 0.25), in: shape)
        .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.75), .white.opacity(0.1)],
                                                   startPoint: .top, endPoint: .bottom), lineWidth: 1))
        .rotation3DEffect(.degrees(hovering ? -14 : 0), axis: (x: 1, y: 0, z: 0), anchor: .bottom, perspective: 0.6)
    }

    private func loadThumbnails() async {
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
            // Files first (their thumbnails show content), then subfolders as folder icons.
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                let db = (try? b.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                if da != db { return !da }
                return a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
            }
            .prefix(3)
        var images: [NSImage] = []
        for file in files {
            let request = QLThumbnailGenerator.Request(fileAt: file, size: CGSize(width: 96, height: 120),
                                                       scale: NSScreen.main?.backingScaleFactor ?? 2,
                                                       representationTypes: .all)
            if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                images.append(rep.nsImage)
            }
        }
        thumbnails = images
    }
}

/// The back of a folder: a body with a tab on the upper left.
private struct FolderBackShape: Shape {
    func path(in rect: CGRect) -> Path {
        let r: CGFloat = 18
        let tabWidth = rect.width * 0.38
        let tabHeight: CGFloat = 16
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + r))
        p.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + tabWidth - 10, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + tabWidth + 14, y: rect.minY + tabHeight),
                       control: CGPoint(x: rect.minX + tabWidth + 2, y: rect.minY + tabHeight))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY + tabHeight))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + tabHeight + r), control: CGPoint(x: rect.maxX, y: rect.minY + tabHeight))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Dot-matrix loader

/// A grid of dots that breathes around two slowly moving bright spots, for long waits.
struct DotMatrixLoader: View {
    var columns = 14
    var dotSize: CGFloat = 5
    var spacing: CGFloat = 4
    var color: Color = .accentColor

    var body: some View {
        let side = CGFloat(columns) * dotSize + CGFloat(columns - 1) * spacing
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, _ in
                let n = Double(columns - 1)
                let foci = [
                    CGPoint(x: (sin(t * 0.9) * 0.5 + 0.5) * n, y: (cos(t * 0.7) * 0.5 + 0.5) * n),
                    CGPoint(x: (cos(t * 0.6 + 1.3) * 0.5 + 0.5) * n, y: (sin(t * 1.1 + 0.4) * 0.5 + 0.5) * n),
                ]
                for row in 0..<columns {
                    for col in 0..<columns {
                        let glow = foci.map { focus -> Double in
                            let dx = Double(col) - focus.x, dy = Double(row) - focus.y
                            return exp(-(dx * dx + dy * dy) / 6)
                        }.max() ?? 0
                        let breathe = 0.5 + 0.5 * sin(t * 2 + Double(row + col) * 0.35)
                        let alpha = 0.10 + 0.9 * glow + 0.06 * breathe
                        let scale = 0.55 + 0.45 * glow
                        let size = dotSize * scale
                        let x = CGFloat(col) * (dotSize + spacing) + (dotSize - size) / 2
                        let y = CGFloat(row) * (dotSize + spacing) + (dotSize - size) / 2
                        ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: size, height: size)),
                                 with: .color(color.opacity(min(1, alpha))))
                    }
                }
            }
        }
        .frame(width: side, height: side)
        .accessibilityLabel(Text("正在加载"))
    }
}

/// The dot matrix with a caption on a glass card, laid over whatever is waiting.
struct DotMatrixWaitingCard: View {
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            DotMatrixLoader()
            Text(message).font(.callout).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .glassPanel(cornerRadius: 20)
    }
}

// MARK: - Progressive blur edges

/// Scrolling content fades into a soft blur at the top and bottom instead of being cut off.
struct ProgressiveBlurEdges: ViewModifier {
    var top: CGFloat = 18
    var bottom: CGFloat = 22

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) { edge(height: top, fromTop: true) }
            .overlay(alignment: .bottom) { edge(height: bottom, fromTop: false) }
    }

    private func edge(height: CGFloat, fromTop: Bool) -> some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .mask(LinearGradient(colors: [.black, .black.opacity(0)],
                                 startPoint: fromTop ? .top : .bottom, endPoint: fromTop ? .bottom : .top))
            .frame(height: height)
            .allowsHitTesting(false)
    }
}

extension View {
    func progressiveBlurEdges(top: CGFloat = 18, bottom: CGFloat = 22) -> some View {
        modifier(ProgressiveBlurEdges(top: top, bottom: bottom))
    }
}

// MARK: - Command bar (⌘K)

/// A glass search bar over the window: type to jump to a repository or run an action.
struct CommandBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @AppStorage("repositoryList.selection") private var selectionID = ""
    @Binding var isPresented: Bool

    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    private struct Entry: Identifiable {
        let id: String
        let title: String
        let subtitle: String?
        let symbol: String
        let run: () -> Void
    }

    var body: some View {
        let entries = filtered
        ZStack(alignment: .top) {
            Color.black.opacity(0.12)
                .ignoresSafeArea()
                .onTapGesture { close() }
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索仓库或操作", text: $query)
                        .textFieldStyle(.plain)
                        .font(.title3)
                        .focused($focused)
                        .onSubmit { runHighlighted(entries) }
                    Text("esc").font(.caption.monospaced()).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                Divider().opacity(0.5)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                                row(entry, selected: index == highlighted)
                                    .id(index)
                                    .onTapGesture { entry.run(); close() }
                                    .onHover { if $0 { highlighted = index } }
                            }
                            if entries.isEmpty {
                                Text("没有匹配的结果").foregroundStyle(.secondary).padding(20)
                            }
                        }
                        .padding(8)
                    }
                    .frame(maxHeight: 340)
                    .onChange(of: highlighted) { _, value in proxy.scrollTo(value) }
                }
            }
            .frame(width: 540)
            .fixedSize(horizontal: false, vertical: true)
            .glassPanel(cornerRadius: 20)
            .shadow(color: .black.opacity(0.25), radius: 30, y: 16)
            .padding(.top, 90)
        }
        .onAppear { focused = true }
        .onChange(of: query) { highlighted = 0 }
        .onKeyPress(.downArrow) { highlighted = min(highlighted + 1, max(0, entries.count - 1)); return .handled }
        .onKeyPress(.upArrow) { highlighted = max(highlighted - 1, 0); return .handled }
        .onKeyPress(.escape) { close(); return .handled }
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
    }

    private func row(_ entry: Entry, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.symbol)
                .frame(width: 22)
                .foregroundStyle(selected ? .white : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).lineLimit(1)
                if let subtitle = entry.subtitle {
                    Text(subtitle).font(.caption).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(selected ? .white.opacity(0.8) : .secondary)
                }
            }
            Spacer(minLength: 0)
            if selected { Image(systemName: "return").font(.caption).foregroundStyle(.white.opacity(0.8)) }
        }
        .foregroundStyle(selected ? .white : .primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor)
            }
        }
        .contentShape(Rectangle())
    }

    private var current: RepositoryConfig? {
        model.repositories.first { $0.id.uuidString == selectionID } ?? model.repositories.first
    }

    private var entries: [Entry] {
        var list: [Entry] = model.repositories.map { repo in
            Entry(id: "repo-\(repo.id)", title: repo.displayName, subtitle: repo.path, symbol: "folder") {
                selectionID = repo.id.uuidString
                // Leave version history, otherwise the newly selected repository stays hidden behind it.
                model.historyRequest = nil
            }
        }
        if let repo = current {
            list.append(Entry(id: "sync-one", title: String(localized: "立即同步「\(repo.displayName)」"), subtitle: nil,
                              symbol: "arrow.triangle.2.circlepath") { model.sync(repo.id, trigger: .manualSingle) })
            list.append(Entry(id: "history", title: String(localized: "打开「\(repo.displayName)」的历史版本"), subtitle: nil,
                              symbol: "clock.arrow.circlepath") {
                model.historyRequest = HistoryRequest(repoID: repo.id)
            })
            list.append(Entry(id: "finder", title: String(localized: "在 Finder 中显示「\(repo.displayName)」"), subtitle: nil,
                              symbol: "folder.badge.gearshape") { model.revealInFinder(repo.id) })
            list.append(Entry(id: "github", title: String(localized: "在 GitHub 上打开「\(repo.displayName)」"), subtitle: nil,
                              symbol: "safari") { model.openOnGitHub(repo.id) })
        }
        list.append(Entry(id: "sync-all", title: String(localized: "立即同步全部"), subtitle: nil,
                          symbol: "arrow.clockwise.icloud") { model.syncAll(trigger: .manualAll) })
        list.append(Entry(id: "add", title: String(localized: "添加仓库…"), subtitle: nil,
                          symbol: "plus") { RepositoryPicker.present(model: model) })
        if model.auth.state.isUsable {
            list.append(Entry(id: "download", title: String(localized: "从 GitHub 下载…"), subtitle: nil,
                              symbol: "icloud.and.arrow.down") { model.activeSheet = .downloadFromGitHub })
        }
        list.append(Entry(id: "logs", title: String(localized: "查看同步日志"), subtitle: nil,
                          symbol: "list.bullet.rectangle") { openWindow(id: WindowID.logs) })
        list.append(Entry(id: "settings", title: String(localized: "设置"), subtitle: nil,
                          symbol: "gearshape") { openSettings() })
        return list
    }

    private var filtered: [Entry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return entries }
        return entries.filter { $0.title.localizedCaseInsensitiveContains(q) || ($0.subtitle?.localizedCaseInsensitiveContains(q) ?? false) }
    }

    private func runHighlighted(_ entries: [Entry]) {
        guard entries.indices.contains(highlighted) else { return }
        entries[highlighted].run()
        close()
    }

    private func close() {
        withAnimation(.easeOut(duration: 0.15)) { isPresented = false }
    }
}
