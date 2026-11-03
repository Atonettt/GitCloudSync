import Foundation

/// Maintains a managed block in `.git/info/exclude`.
///
/// Using `info/exclude` keeps the user's `.gitignore` untouched and the rules local to this Mac.
/// Files that are already tracked are not affected by ignore rules (a Git limitation).
public enum IgnoreRules {
    public static let defaultPatterns: [String] = [
        ".DS_Store",
        "._*",
        ".Spotlight-V100",
        ".Trashes",
        ".fseventsd",
        ".TemporaryItems",
        "~$*",          // Word / Excel / PowerPoint owner files
        ".~lock.*#",    // LibreOffice lock files
        "~*.tmp",       // Office temp files
        "*.tmp",
        "*.swp",
        "Thumbs.db",
        "desktop.ini",
    ]

    // Markers keep the app's original name so blocks already written to repositories are still found.
    static let beginMarker = "# >>> GitCloud Sync managed rules (edit in the app) >>>"
    static let endMarker = "# <<< GitCloud Sync managed rules <<<"

    public static func apply(patterns: [String], gitDirectory: URL) throws {
        let infoDir = gitDirectory.appendingPathComponent("info", isDirectory: true)
        let file = infoDir.appendingPathComponent("exclude")
        let existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let updated = render(existing: existing, patterns: patterns)
        guard updated != existing else { return }
        try FileManager.default.createDirectory(at: infoDir, withIntermediateDirectories: true)
        try updated.write(to: file, atomically: true, encoding: .utf8)
    }

    static func render(existing: String, patterns: [String]) -> String {
        var lines = existing.components(separatedBy: "\n")
        if let start = lines.firstIndex(of: beginMarker),
           let end = lines[start...].firstIndex(of: endMarker) {
            lines.removeSubrange(start...end)
        }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        let cleaned = patterns
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if !cleaned.isEmpty {
            if !lines.isEmpty { lines.append("") }
            lines.append(beginMarker)
            lines.append(contentsOf: cleaned)
            lines.append(endMarker)
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }
}
