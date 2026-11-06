import SwiftUI

/// What changed between two versions of a file: edited, added and removed paragraphs for text
/// (including Word and PDF), changed cells for Excel, both pictures for images.
struct VersionComparisonView: View {
    /// The earlier version; nil when the file did not exist yet.
    let old: URL?
    /// The later version; nil when the file was deleted.
    let new: URL?
    /// The file's own extension (exported versions may carry a label in the name).
    let kind: String
    /// Names the earlier version, for example "与 11月6日 10:32 的版本相比".
    let caption: String

    private enum Result {
        case text([TextDiff.Line])
        case sheets([SheetDiff.Change])
        case images(NSImage?, NSImage?)
        case opaque(old: Int64?, new: Int64?)
        case mixed
    }

    @State private var result: Result?

    var body: some View {
        Group {
            if old == nil || new == nil {
                // Nothing to set side by side: say what happened instead of listing every line.
                VStack(spacing: 0) {
                    ComparisonHeader(caption: caption, detail: "") { EmptyView() }
                    Divider()
                    if old == nil {
                        ContentUnavailableView("这是新添加的文件", systemImage: "doc.badge.plus",
                                               description: Text("之前没有这个文件，切到「预览」可以查看全部内容。"))
                    } else {
                        ContentUnavailableView("这个文件已被删除", systemImage: "trash",
                                               description: Text("现在没有这个文件了。"))
                    }
                }
            } else if let result {
                switch result {
                case .text(let lines): TextComparison(lines: lines, caption: caption)
                case .sheets(let changes): SheetComparison(changes: changes, caption: caption)
                case .images(let before, let after): ImageComparison(old: before, new: after, caption: caption)
                case .opaque(let before, let after): OpaqueComparison(old: before, new: after, caption: caption)
                case .mixed: OpaqueComparison(old: nil, new: nil, caption: caption)
                }
            } else {
                ProgressView("正在对比…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: "\(old?.path ?? "-")|\(new?.path ?? "-")") {
            result = nil
            result = await compare()
        }
    }

    private func compare() async -> Result {
        let before: ComparableContent? = if let old { await ComparableContent.load(old, kind: kind) } else { nil }
        let after: ComparableContent? = if let new { await ComparableContent.load(new, kind: kind) } else { nil }
        return await Task.detached(priority: .userInitiated) { () -> Result in
            switch (before, after) {
            case (.text(let a)?, .text(let b)?): return .text(TextDiff.compare(old: a, new: b))
            case (nil, .text(let b)?): return .text(TextDiff.compare(old: "", new: b))
            case (.text(let a)?, nil): return .text(TextDiff.compare(old: a, new: ""))
            case (.sheets(let a)?, .sheets(let b)?): return .sheets(SheetDiff.compare(old: a, new: b))
            case (nil, .sheets(let b)?): return .sheets(SheetDiff.compare(old: [:], new: b))
            case (.sheets(let a)?, nil): return .sheets(SheetDiff.compare(old: a, new: [:]))
            case (.image(let a)?, .image(let b)?): return .images(a, b)
            case (nil, .image(let b)?): return .images(nil, b)
            case (.image(let a)?, nil): return .images(a, nil)
            case (.opaque(let a)?, .opaque(let b)?): return .opaque(old: a, new: b)
            case (nil, .opaque(let b)?): return .opaque(old: nil, new: b)
            case (.opaque(let a)?, nil): return .opaque(old: a, new: nil)
            default: return .mixed
            }
        }.value
    }
}

// MARK: - Text

private struct TextComparison: View {
    let lines: [TextDiff.Line]
    let caption: String

    /// Unchanged lines shown around each change; longer unchanged runs fold away.
    private static let context = 2

    private enum Block: Identifiable {
        case line(Int)
        case folded(Range<Int>)
        var id: String {
            switch self {
            case .line(let index): "l\(index)"
            case .folded(let range): "f\(range.lowerBound)"
            }
        }
    }

    @State private var expanded: Set<Int> = []
    @State private var current = 0

    var body: some View {
        let summary = TextDiff.summary(of: lines)
        let changes = changeStarts
        VStack(spacing: 0) {
            ComparisonHeader(caption: caption, detail: summaryText(summary)) {
                if changes.count > 1 {
                    ControlGroup {
                        Button { step(-1, changes.count) } label: { Image(systemName: "chevron.up") }
                            .help("上一处改动")
                        Button { step(1, changes.count) } label: { Image(systemName: "chevron.down") }
                            .help("下一处改动")
                    }
                    .fixedSize()
                }
            }
            Divider()
            if summary.total == 0 {
                ContentUnavailableView("没有改动", systemImage: "equal.circle",
                                       description: Text("文字和上一个时间节点完全一样。如果文件确实改过，可能只改了格式、图片等无法比较文字的地方。"))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(blocks) { block in
                                switch block {
                                case .line(let index): LineRow(line: lines[index]).id("l\(index)")
                                case .folded(let range):
                                    Button {
                                        expanded.insert(range.lowerBound)
                                    } label: {
                                        Text("… \(range.count) 段未改动，点击展开 …")
                                            .font(.caption).foregroundStyle(.secondary)
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 4)
                                            .background(Color.primary.opacity(0.04))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(.vertical, 8)
                        .textSelection(.enabled)
                    }
                    .onChange(of: current) { _, value in
                        guard changes.indices.contains(value) else { return }
                        withAnimation { proxy.scrollTo("l\(changes[value])", anchor: .center) }
                    }
                }
            }
        }
    }

    private func summaryText(_ summary: TextDiff.Summary) -> String {
        guard summary.total > 0 else { return String(localized: "没有文字改动") }
        var parts: [String] = []
        if summary.changed > 0 { parts.append(String(localized: "修改 \(summary.changed) 段")) }
        if summary.added > 0 { parts.append(String(localized: "新增 \(summary.added) 段")) }
        if summary.removed > 0 { parts.append(String(localized: "删除 \(summary.removed) 段")) }
        return String(localized: "改动 \(changeStarts.count) 处：") + parts.joined(separator: " · ")
    }

    /// The first line of each run of changed lines, for "previous / next change".
    private var changeStarts: [Int] {
        lines.indices.filter { lines[$0].isChange && ($0 == 0 || !lines[$0 - 1].isChange) }
    }

    private func step(_ delta: Int, _ count: Int) {
        current = (current + delta + count) % count
    }

    private var blocks: [Block] {
        var keep = Set<Int>()
        for (index, line) in lines.enumerated() where line.isChange {
            for near in max(0, index - Self.context)...min(lines.count - 1, index + Self.context) { keep.insert(near) }
        }
        var result: [Block] = []
        var index = 0
        while index < lines.count {
            if keep.contains(index) {
                result.append(.line(index)); index += 1; continue
            }
            var end = index
            while end < lines.count, !keep.contains(end) { end += 1 }
            if end - index <= 3 || expanded.contains(index) {
                result += (index..<end).map(Block.line)
            } else {
                result.append(.folded(index..<end))
            }
            index = end
        }
        return result
    }
}

private struct LineRow: View {
    let line: TextDiff.Line

    var body: some View {
        switch line {
        case .same(let text):
            row(Text(text.isEmpty ? " " : text), marker: " ", tint: nil)
        case .added(let text):
            row(Text(text.isEmpty ? " " : text), marker: "+", tint: .green)
        case .removed(let text):
            row(Text(text.isEmpty ? " " : text).strikethrough(color: .red.opacity(0.6)), marker: "−", tint: .red)
        case .changed(let old, let new):
            VStack(spacing: 0) {
                row(Text(attributed(old, color: .red, strike: true)), marker: "−", tint: .red, faint: true)
                row(Text(attributed(new, color: .green, strike: false)), marker: "+", tint: .green, faint: true)
            }
        }
    }

    private func row(_ text: Text, marker: String, tint: Color?, faint: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(marker)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(tint ?? .secondary)
                .frame(width: 12)
            text
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .background(tint.map { $0.opacity(faint ? 0.06 : 0.12) } ?? Color.clear)
    }

    private func attributed(_ segments: [TextDiff.Segment], color: Color, strike: Bool) -> AttributedString {
        var result = AttributedString()
        for segment in segments {
            var part = AttributedString(segment.text)
            if segment.changed {
                part.backgroundColor = color.opacity(0.3)
                if strike { part.strikethroughStyle = .single }
            }
            result += part
        }
        return result
    }
}

// MARK: - Spreadsheets

private struct SheetComparison: View {
    let changes: [SheetDiff.Change]
    let caption: String

    var body: some View {
        VStack(spacing: 0) {
            ComparisonHeader(caption: caption,
                             detail: changes.isEmpty ? String(localized: "单元格内容没有变化") : String(localized: "改动 \(changes.count) 个单元格")) { EmptyView() }
            Divider()
            if changes.isEmpty {
                ContentUnavailableView("单元格内容没有变化", systemImage: "equal.circle",
                                       description: Text("可能只改了格式、批注或图表。"))
            } else {
                Table(changes) {
                    TableColumn("工作表", value: \.sheet).width(min: 60, ideal: 90)
                    TableColumn("单元格", value: \.cell).width(min: 50, ideal: 60)
                    TableColumn("原来") { change in
                        Text(change.old ?? "—").foregroundStyle(change.old == nil ? .secondary : .primary)
                            .strikethrough(change.old != nil && change.new == nil)
                    }
                    TableColumn("现在") { change in
                        Text(change.new ?? String(localized: "（已清空）"))
                            .foregroundStyle(change.new == nil ? .secondary : .primary)
                    }
                }
            }
        }
    }
}

// MARK: - Images

private struct ImageComparison: View {
    let old: NSImage?
    let new: NSImage?
    let caption: String
    @State private var overlay = false
    @State private var amount = 0.5

    var body: some View {
        VStack(spacing: 0) {
            ComparisonHeader(caption: caption, detail: String(localized: "左边是之前，右边是现在")) {
                if old != nil, new != nil {
                    Toggle("叠加对比", isOn: $overlay).toggleStyle(.switch).controlSize(.small)
                }
            }
            Divider()
            if overlay, let old, let new {
                VStack {
                    ZStack {
                        Image(nsImage: old).resizable().scaledToFit()
                        Image(nsImage: new).resizable().scaledToFit().opacity(amount)
                    }
                    Slider(value: $amount, in: 0...1) {
                        Text("之前 ↔ 现在")
                    }
                    .frame(maxWidth: 320)
                }
                .padding()
            } else {
                HStack(spacing: 12) {
                    side(old, label: String(localized: "之前"), missing: String(localized: "那时还没有这个文件"))
                    side(new, label: String(localized: "现在"), missing: String(localized: "文件已删除"))
                }
                .padding()
            }
        }
    }

    private func side(_ image: NSImage?, label: String, missing: String) -> some View {
        VStack(spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text(missing).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// MARK: - Other files

private struct OpaqueComparison: View {
    let old: Int64?
    let new: Int64?
    let caption: String

    var body: some View {
        VStack(spacing: 0) {
            ComparisonHeader(caption: caption, detail: "") { EmptyView() }
            Divider()
            ContentUnavailableView {
                Label("无法逐处对比这种文件", systemImage: "doc.questionmark")
            } description: {
                Text(sizeText)
            }
        }
    }

    private var sizeText: String {
        func format(_ bytes: Int64?) -> String {
            bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—"
        }
        if old == nil, new == nil { return String(localized: "里面没有可以比较的文字。") }
        return String(localized: "大小：\(format(old)) → \(format(new))")
    }
}

private struct ComparisonHeader<Trailing: View>: View {
    let caption: String
    let detail: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(caption).font(.caption).foregroundStyle(.secondary)
                if !detail.isEmpty { Text(detail).font(.callout.weight(.medium)) }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
