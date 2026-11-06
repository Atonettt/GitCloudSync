using System.Text.RegularExpressions;

namespace GitSync.Core;

/// <summary>
/// Maintains a managed block in <c>.git/info/exclude</c>, so the user's .gitignore stays untouched
/// and the rules stay local to this computer. Files already tracked are not affected (a Git limitation).
/// </summary>
public static class IgnoreRules
{
    public static readonly IReadOnlyList<string> DefaultPatterns =
    [
        ".DS_Store", "._*", ".Spotlight-V100", ".Trashes", ".fseventsd", ".TemporaryItems",
        "~$*",          // Word / Excel / PowerPoint owner files
        ".~lock.*#",    // LibreOffice lock files
        "~*.tmp",       // Office temp files
        "*.tmp", "*.swp", "Thumbs.db", "desktop.ini", "$RECYCLE.BIN",
    ];

    // The same markers as the Mac app, so both manage the same block.
    const string BeginMarker = "# >>> GitCloud Sync managed rules (edit in the app) >>>";
    const string EndMarker = "# <<< GitCloud Sync managed rules <<<";

    public static void Apply(IEnumerable<string> patterns, string gitDirectory)
    {
        var info = Path.Combine(gitDirectory, "info");
        var file = Path.Combine(info, "exclude");
        var existing = File.Exists(file) ? File.ReadAllText(file) : "";
        var updated = Render(existing, patterns);
        if (updated == existing) return;
        Directory.CreateDirectory(info);
        File.WriteAllText(file, updated);
    }

    public static string Render(string existing, IEnumerable<string> patterns)
    {
        var lines = existing.Replace("\r\n", "\n").Split('\n').ToList();
        var start = lines.IndexOf(BeginMarker);
        if (start >= 0)
        {
            var end = lines.IndexOf(EndMarker, start);
            if (end >= 0) lines.RemoveRange(start, end - start + 1);
        }
        while (lines.Count > 0 && string.IsNullOrWhiteSpace(lines[^1])) lines.RemoveAt(lines.Count - 1);
        var cleaned = patterns.Select(p => p.Trim()).Where(p => p.Length > 0).ToList();
        if (cleaned.Count > 0)
        {
            if (lines.Count > 0) lines.Add("");
            lines.Add(BeginMarker);
            lines.AddRange(cleaned);
            lines.Add(EndMarker);
        }
        return lines.Count == 0 ? "" : string.Join("\n", lines) + "\n";
    }

    /// <summary>Whether a file name matches one of the patterns (simple glob, names only).</summary>
    public static bool IsIgnored(string name, IEnumerable<string> patterns) =>
        patterns.Any(pattern => Glob(pattern).IsMatch(name));

    static Regex Glob(string pattern) =>
        new("^" + Regex.Escape(pattern.Trim().TrimEnd('/')).Replace(@"\*", ".*").Replace(@"\?", ".") + "$",
            RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
}
