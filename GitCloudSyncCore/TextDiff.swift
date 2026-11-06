import Foundation

/// Paragraph-by-paragraph comparison of two texts, with the changed characters marked inside
/// paragraphs that were edited rather than replaced. Used to show what changed between versions.
public enum TextDiff {
    /// A run of characters, marked when it differs from the other version.
    public struct Segment: Hashable, Sendable {
        public let text: String
        public let changed: Bool
    }

    public enum Line: Hashable, Sendable {
        case same(String)
        case added(String)
        case removed(String)
        /// The same paragraph, edited: `old` marks what was taken out, `new` what was put in.
        case changed(old: [Segment], new: [Segment])

        public var isChange: Bool {
            if case .same = self { return false }
            return true
        }
    }

    public struct Summary: Hashable, Sendable {
        public var added = 0
        public var removed = 0
        public var changed = 0
        public var total: Int { added + removed + changed }
    }

    /// Paragraphs longer than this are compared as a whole, not character by character.
    static let characterDiffLimit = 4000
    /// How alike two paragraphs must be (0...1) to count as one edited paragraph.
    static let pairingThreshold = 0.4

    public static func compare(old: String, new: String) -> [Line] {
        let oldLines = paragraphs(old)
        let newLines = paragraphs(new)
        let difference = newLines.difference(from: oldLines)
        var removedOffsets = Set<Int>()
        var insertedOffsets = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removedOffsets.insert(offset)
            case .insert(let offset, _, _): insertedOffsets.insert(offset)
            }
        }

        var raw: [Line] = []
        var i = 0, j = 0
        while i < oldLines.count || j < newLines.count {
            if i < oldLines.count, removedOffsets.contains(i) {
                raw.append(.removed(oldLines[i])); i += 1
            } else if j < newLines.count, insertedOffsets.contains(j) {
                raw.append(.added(newLines[j])); j += 1
            } else if i < oldLines.count, j < newLines.count {
                raw.append(.same(newLines[j])); i += 1; j += 1
            } else if i < oldLines.count {
                raw.append(.removed(oldLines[i])); i += 1
            } else {
                raw.append(.added(newLines[j])); j += 1
            }
        }
        return pairEdits(raw)
    }

    public static func summary(of lines: [Line]) -> Summary {
        var summary = Summary()
        for line in lines {
            switch line {
            case .same: break
            case .added: summary.added += 1
            case .removed: summary.removed += 1
            case .changed: summary.changed += 1
            }
        }
        return summary
    }

    /// Non-blank lines without trailing whitespace. Blank lines (Word documents are full of them)
    /// carry no content, so adding or removing them is not shown as a change.
    static func paragraphs(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { line in
                var line = line
                while let last = line.last, last.isWhitespace { line.removeLast() }
                return line
            }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Turns "removed paragraph, added paragraph" pairs that are mostly alike into one edited paragraph.
    private static func pairEdits(_ lines: [Line]) -> [Line] {
        var result: [Line] = []
        var index = 0
        while index < lines.count {
            guard case .removed = lines[index] else {
                result.append(lines[index]); index += 1; continue
            }
            var removed: [String] = []
            while index < lines.count, case .removed(let text) = lines[index] { removed.append(text); index += 1 }
            var added: [String] = []
            while index < lines.count, case .added(let text) = lines[index] { added.append(text); index += 1 }

            let pairs = min(removed.count, added.count)
            var leftoverRemoved: [String] = []
            var leftoverAdded: [String] = []
            var paired: [Line] = []
            for k in 0..<pairs {
                if let edit = edit(from: removed[k], to: added[k]) {
                    paired.append(edit)
                } else {
                    leftoverRemoved.append(removed[k])
                    leftoverAdded.append(added[k])
                }
            }
            leftoverRemoved += removed.dropFirst(pairs)
            leftoverAdded += added.dropFirst(pairs)
            result += paired
            result += leftoverRemoved.map(Line.removed)
            result += leftoverAdded.map(Line.added)
        }
        return result
    }

    /// The character-level edit between two paragraphs, or nil when they have too little in common.
    static func edit(from old: String, to new: String) -> Line? {
        let a = Array(old), b = Array(new)
        guard a.count <= characterDiffLimit, b.count <= characterDiffLimit, !a.isEmpty, !b.isEmpty else { return nil }
        let difference = b.difference(from: a)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        let kept = a.count - removed.count
        let similarity = Double(2 * kept) / Double(a.count + b.count)
        guard similarity >= pairingThreshold else { return nil }
        return .changed(old: segments(a, marked: removed), new: segments(b, marked: inserted))
    }

    private static func segments(_ characters: [Character], marked: Set<Int>) -> [Segment] {
        var result: [Segment] = []
        var current = ""
        var currentChanged = false
        for (offset, character) in characters.enumerated() {
            let changed = marked.contains(offset)
            if !current.isEmpty, changed != currentChanged {
                result.append(Segment(text: current, changed: currentChanged))
                current = ""
            }
            currentChanged = changed
            current.append(character)
        }
        if !current.isEmpty { result.append(Segment(text: current, changed: currentChanged)) }
        return result
    }
}

/// Cell-by-cell comparison of two spreadsheets: sheet name → cell reference ("B5") → shown value.
public enum SheetDiff {
    public struct Change: Hashable, Sendable, Identifiable {
        public let sheet: String
        public let cell: String
        public let old: String?
        public let new: String?
        public var id: String { sheet + "!" + cell }
    }

    public static func compare(old: [String: [String: String]], new: [String: [String: String]]) -> [Change] {
        var changes: [Change] = []
        let sheets = Array(Set(old.keys).union(new.keys))
        for sheet in sheets {
            let a = old[sheet] ?? [:], b = new[sheet] ?? [:]
            for cell in Set(a.keys).union(b.keys) where a[cell] != b[cell] {
                changes.append(Change(sheet: sheet, cell: cell, old: a[cell], new: b[cell]))
            }
        }
        return changes.sorted { lhs, rhs in
            if lhs.sheet != rhs.sheet { return lhs.sheet.localizedStandardCompare(rhs.sheet) == .orderedAscending }
            return cellOrder(lhs.cell) < cellOrder(rhs.cell)
        }
    }

    /// Row first, then column, so changes read top to bottom.
    static func cellOrder(_ reference: String) -> (Int, Int) {
        let letters = reference.prefix { $0.isLetter }
        let row = Int(reference.dropFirst(letters.count)) ?? 0
        let column = letters.uppercased().unicodeScalars.reduce(0) { $0 * 26 + Int($1.value) - 64 }
        return (row, column)
    }
}
