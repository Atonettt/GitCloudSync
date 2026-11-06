namespace GitSync.Core;

/// <summary>Myers' O(ND) difference: which items of <c>a</c> were removed and which of <c>b</c> inserted.</summary>
public static class Myers
{
    public static (HashSet<int> Removed, HashSet<int> Inserted) Diff<T>(IReadOnlyList<T> a, IReadOnlyList<T> b, IEqualityComparer<T>? comparer = null)
    {
        comparer ??= EqualityComparer<T>.Default;
        int n = a.Count, m = b.Count, max = n + m;
        var removed = new HashSet<int>();
        var inserted = new HashSet<int>();
        if (max == 0) return (removed, inserted);

        var v = new int[2 * max + 2];
        var trace = new List<int[]>();
        var offset = max;
        var found = false;
        for (var d = 0; d <= max && !found; d++)
        {
            trace.Add((int[])v.Clone());
            for (var k = -d; k <= d; k += 2)
            {
                int x = k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]) ? v[offset + k + 1] : v[offset + k - 1] + 1;
                var y = x - k;
                while (x < n && y < m && comparer.Equals(a[x], b[y])) { x++; y++; }
                v[offset + k] = x;
                if (x >= n && y >= m) { found = true; break; }
            }
        }

        // Walk back through the saved frontiers to recover the edit script.
        int cx = n, cy = m;
        for (var d = trace.Count - 1; d > 0; d--)
        {
            var frontier = trace[d];
            var k = cx - cy;
            var prevK = k == -d || (k != d && frontier[offset + k - 1] < frontier[offset + k + 1]) ? k + 1 : k - 1;
            var prevX = frontier[offset + prevK];
            var prevY = prevX - prevK;
            while (cx > prevX && cy > prevY) { cx--; cy--; }
            if (cx == prevX) inserted.Add(prevY); else removed.Add(prevX);
            cx = prevX;
            cy = prevY;
        }
        return (removed, inserted);
    }
}

/// <summary>
/// Paragraph-by-paragraph comparison of two texts, with the changed characters marked inside
/// paragraphs that were edited rather than replaced.
/// </summary>
public static class TextDiff
{
    public sealed record Segment(string Text, bool Changed);

    public abstract record Line
    {
        public sealed record Same(string Text) : Line;
        public sealed record Added(string Text) : Line;
        public sealed record Removed(string Text) : Line;
        /// <summary>The same paragraph, edited: Old marks what was taken out, New what was put in.</summary>
        public sealed record Changed(IReadOnlyList<Segment> Old, IReadOnlyList<Segment> New) : Line
        {
            public bool Equals(Changed? other) => other != null && Old.SequenceEqual(other.Old) && New.SequenceEqual(other.New);
            public override int GetHashCode() => Old.Count ^ New.Count;
        }

        public bool IsChange => this is not Same;
    }

    public sealed record Summary(int Added, int Removed, int Changed)
    {
        public int Total => Added + Removed + Changed;
    }

    const int CharacterDiffLimit = 4000;
    const double PairingThreshold = 0.4;

    public static List<Line> Compare(string oldText, string newText)
    {
        var oldLines = Paragraphs(oldText);
        var newLines = Paragraphs(newText);
        var (removed, inserted) = Myers.Diff(oldLines, newLines, StringComparer.Ordinal);

        var raw = new List<Line>();
        int i = 0, j = 0;
        while (i < oldLines.Count || j < newLines.Count)
        {
            if (i < oldLines.Count && removed.Contains(i)) raw.Add(new Line.Removed(oldLines[i++]));
            else if (j < newLines.Count && inserted.Contains(j)) raw.Add(new Line.Added(newLines[j++]));
            else if (i < oldLines.Count && j < newLines.Count) { raw.Add(new Line.Same(newLines[j])); i++; j++; }
            else if (i < oldLines.Count) raw.Add(new Line.Removed(oldLines[i++]));
            else raw.Add(new Line.Added(newLines[j++]));
        }
        return PairEdits(raw);
    }

    public static Summary Summarize(IEnumerable<Line> lines)
    {
        int added = 0, removed = 0, changed = 0;
        foreach (var line in lines)
        {
            switch (line)
            {
                case Line.Added: added++; break;
                case Line.Removed: removed++; break;
                case Line.Changed: changed++; break;
            }
        }
        return new Summary(added, removed, changed);
    }

    /// <summary>Non-blank lines without trailing whitespace; blank lines carry no content.</summary>
    public static List<string> Paragraphs(string text) =>
        text.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n')
            .Select(line => line.TrimEnd())
            .Where(line => line.Trim().Length > 0)
            .ToList();

    /// <summary>Turns "removed paragraph, added paragraph" pairs that are mostly alike into one edited paragraph.</summary>
    static List<Line> PairEdits(List<Line> lines)
    {
        var result = new List<Line>();
        for (var index = 0; index < lines.Count;)
        {
            if (lines[index] is not Line.Removed) { result.Add(lines[index++]); continue; }
            var removed = new List<string>();
            while (index < lines.Count && lines[index] is Line.Removed r) { removed.Add(r.Text); index++; }
            var added = new List<string>();
            while (index < lines.Count && lines[index] is Line.Added a) { added.Add(a.Text); index++; }

            var pairs = Math.Min(removed.Count, added.Count);
            var leftoverRemoved = new List<string>();
            var leftoverAdded = new List<string>();
            var paired = new List<Line>();
            for (var k = 0; k < pairs; k++)
            {
                if (Edit(removed[k], added[k]) is { } edit) paired.Add(edit);
                else { leftoverRemoved.Add(removed[k]); leftoverAdded.Add(added[k]); }
            }
            leftoverRemoved.AddRange(removed.Skip(pairs));
            leftoverAdded.AddRange(added.Skip(pairs));
            result.AddRange(paired);
            result.AddRange(leftoverRemoved.Select(t => (Line)new Line.Removed(t)));
            result.AddRange(leftoverAdded.Select(t => (Line)new Line.Added(t)));
        }
        return result;
    }

    /// <summary>The character-level edit between two paragraphs, or null when they have too little in common.</summary>
    public static Line? Edit(string oldText, string newText)
    {
        var a = TextElements(oldText);
        var b = TextElements(newText);
        if (a.Count > CharacterDiffLimit || b.Count > CharacterDiffLimit || a.Count == 0 || b.Count == 0) return null;
        var (removed, inserted) = Myers.Diff(a, b, StringComparer.Ordinal);
        var kept = a.Count - removed.Count;
        var similarity = 2.0 * kept / (a.Count + b.Count);
        if (similarity < PairingThreshold) return null;
        return new Line.Changed(Segments(a, removed), Segments(b, inserted));
    }

    /// <summary>User-perceived characters, so an emoji or a combined character is never split.</summary>
    static List<string> TextElements(string text)
    {
        var list = new List<string>();
        var enumerator = System.Globalization.StringInfo.GetTextElementEnumerator(text);
        while (enumerator.MoveNext()) list.Add(enumerator.GetTextElement());
        return list;
    }

    static List<Segment> Segments(List<string> characters, HashSet<int> marked)
    {
        var result = new List<Segment>();
        var current = new System.Text.StringBuilder();
        var currentChanged = false;
        for (var offset = 0; offset < characters.Count; offset++)
        {
            var changed = marked.Contains(offset);
            if (current.Length > 0 && changed != currentChanged)
            {
                result.Add(new Segment(current.ToString(), currentChanged));
                current.Clear();
            }
            currentChanged = changed;
            current.Append(characters[offset]);
        }
        if (current.Length > 0) result.Add(new Segment(current.ToString(), currentChanged));
        return result;
    }
}

/// <summary>Cell-by-cell comparison of two spreadsheets: sheet name → cell reference ("B5") → shown value.</summary>
public static class SheetDiff
{
    public sealed record Change(string Sheet, string Cell, string? Old, string? New)
    {
        public string Id => Sheet + "!" + Cell;
    }

    public static List<Change> Compare(Dictionary<string, Dictionary<string, string>> oldSheets,
                                       Dictionary<string, Dictionary<string, string>> newSheets)
    {
        var changes = new List<Change>();
        foreach (var sheet in oldSheets.Keys.Union(newSheets.Keys))
        {
            var a = oldSheets.GetValueOrDefault(sheet) ?? [];
            var b = newSheets.GetValueOrDefault(sheet) ?? [];
            foreach (var cell in a.Keys.Union(b.Keys))
            {
                var before = a.GetValueOrDefault(cell);
                var after = b.GetValueOrDefault(cell);
                if (before != after) changes.Add(new Change(sheet, cell, before, after));
            }
        }
        return changes
            .OrderBy(c => c.Sheet, StringComparer.CurrentCultureIgnoreCase)
            .ThenBy(c => CellOrder(c.Cell).Row)
            .ThenBy(c => CellOrder(c.Cell).Column)
            .ToList();
    }

    /// <summary>Row first, then column, so changes read top to bottom.</summary>
    public static (int Row, int Column) CellOrder(string reference)
    {
        var letters = new string(reference.TakeWhile(char.IsLetter).ToArray());
        _ = int.TryParse(reference[letters.Length..], out var row);
        var column = letters.ToUpperInvariant().Aggregate(0, (total, c) => total * 26 + (c - 'A' + 1));
        return (row, column);
    }
}
