using GitSync.App.Services;
using GitSync.Core;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Storage;
using Windows.Storage.Streams;

namespace GitSync.App.Views;

/// <summary>
/// A file's preview: images and PDF pages as pictures, text and code as text, Word and PowerPoint
/// as their text, Excel as a table. Anything else offers to open the file.
/// </summary>
public static class PreviewView
{
    static readonly HashSet<string> CodeTypes = new(StringComparer.OrdinalIgnoreCase)
        { ".cs", ".swift", ".py", ".js", ".ts", ".json", ".xml", ".yml", ".yaml", ".html", ".css", ".c", ".h", ".cpp", ".java", ".go", ".rs", ".sh", ".ps1", ".toml", ".ini", ".csv", ".tex", ".md" };

    public static async Task<UIElement> CreateAsync(string path, string extension)
    {
        try
        {
            if (ContentExtractor.ImageTypes.Contains(extension))
            {
                var image = new Image { Source = new BitmapImage(new Uri(path)), Stretch = Stretch.Uniform, MaxWidth = 2000 };
                return new ScrollViewer { Content = image, ZoomMode = ZoomMode.Enabled, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, Padding = new Thickness(12) };
            }
            if (extension.Equals(".pdf", StringComparison.OrdinalIgnoreCase)) return await PdfPages(path);

            var content = await ContentExtractor.LoadAsync(path, extension);
            switch (content.Kind)
            {
                case ContentKind.Sheets when content.Sheets is { Count: > 0 } sheets:
                    return SheetTable(sheets);
                case ContentKind.Text:
                    var text = content.Text.Length > 400_000 ? content.Text[..400_000] + "\n…" : content.Text;
                    var block = new TextBlock
                    {
                        Text = text, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true,
                        FontFamily = CodeTypes.Contains(extension) ? new FontFamily("Cascadia Mono, Consolas") : new FontFamily("Segoe UI Variable Text, Microsoft YaHei UI"),
                        FontSize = CodeTypes.Contains(extension) ? 12.5 : 14, LineHeight = CodeTypes.Contains(extension) ? 18 : 22,
                    };
                    var column = Ui.Column(10);
                    if (content.IsDocument)
                        column.Children.Add(Ui.Row(6, Ui.Icon(Glyph.Info, 12, Ui.Secondary),
                            Ui.Caption(L.T("预览只显示文字。要看完整排版，双击用 Office 打开。", "The preview shows the text only; double-click to open it in Office."))));
                    column.Children.Add(block);
                    return new ScrollViewer { Content = column, Padding = new Thickness(20, 12, 20, 12) };
            }
        }
        catch
        {
            // fall through to the generic view
        }
        return OpenWithDefault(path);
    }

    static UIElement OpenWithDefault(string path) => Centered(Ui.Column(12,
        Ui.Icon(Glyph.Document, 48, Ui.Tertiary),
        Ui.Caption(L.T("这种文件无法在这里预览", "This kind of file can't be previewed here")),
        Ui.Button(L.T("用默认程序打开", "Open with Default App"), () => Shell.Open(path), Glyph.Open)));

    public static UIElement Centered(StackPanel panel)
    {
        foreach (var child in panel.Children) if (child is FrameworkElement element) element.HorizontalAlignment = HorizontalAlignment.Center;
        panel.HorizontalAlignment = HorizontalAlignment.Center;
        panel.VerticalAlignment = VerticalAlignment.Center;
        return panel;
    }

    /// <summary>PDF pages rendered by Windows, fitted to the width and scrollable.</summary>
    static async Task<UIElement> PdfPages(string path)
    {
        var file = await StorageFile.GetFileFromPathAsync(path);
        var document = await Windows.Data.Pdf.PdfDocument.LoadFromFileAsync(file);
        var pages = new StackPanel { Spacing = 12, Padding = new Thickness(16) };
        var count = Math.Min(document.PageCount, 60u);
        for (uint index = 0; index < count; index++)
        {
            using var page = document.GetPage(index);
            using var stream = new InMemoryRandomAccessStream();
            await page.RenderToStreamAsync(stream, new Windows.Data.Pdf.PdfPageRenderOptions { DestinationWidth = 1400 });
            var bitmap = new BitmapImage();
            await bitmap.SetSourceAsync(stream);
            pages.Children.Add(new Border
            {
                Child = new Image { Source = bitmap, Stretch = Stretch.Uniform },
                BorderBrush = Ui.CardStroke, BorderThickness = new Thickness(1), Background = new SolidColorBrush(Microsoft.UI.Colors.White),
            });
        }
        if (document.PageCount > count)
            pages.Children.Add(Ui.Caption(L.T($"只显示前 {count} 页，共 {document.PageCount} 页", $"Showing {count} of {document.PageCount} pages")));
        return new ScrollViewer { Content = pages, ZoomMode = ZoomMode.Enabled };
    }

    /// <summary>The first sheet (and the names of the others) as a simple table.</summary>
    static UIElement SheetTable(Dictionary<string, Dictionary<string, string>> sheets)
    {
        var tabs = new TabView { IsAddTabButtonVisible = false, CanReorderTabs = false, TabWidthMode = TabViewWidthMode.SizeToContent };
        foreach (var (name, cells) in sheets.Take(10))
        {
            var grid = new Grid { ColumnSpacing = 0, RowSpacing = 0 };
            var positions = cells.Keys.Select(SheetDiff.CellOrder).ToList();
            var maxRow = Math.Min(positions.Count == 0 ? 0 : positions.Max(p => p.Row), 300);
            var maxColumn = Math.Min(positions.Count == 0 ? 0 : positions.Max(p => p.Column), 40);
            for (var c = 0; c <= maxColumn; c++) grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto, MinWidth = c == 0 ? 36 : 80 });
            for (var r = 0; r <= maxRow; r++) grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            for (var c = 1; c <= maxColumn; c++) grid.Children.Add(Cell(ColumnName(c), true).At(0, c));
            for (var r = 1; r <= maxRow; r++) grid.Children.Add(Cell(r.ToString(), true).At(r, 0));
            foreach (var (reference, value) in cells)
            {
                var (row, column) = SheetDiff.CellOrder(reference);
                if (row <= maxRow && column <= maxColumn && row > 0 && column > 0) grid.Children.Add(Cell(value, false).At(row, column));
            }
            tabs.TabItems.Add(new TabViewItem
            {
                Header = name, IsClosable = false,
                Content = new ScrollViewer { Content = grid, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollMode = ScrollMode.Enabled, Padding = new Thickness(8) },
            });
        }
        return tabs;
    }

    static Border Cell(string text, bool header) => new()
    {
        Child = new TextBlock { Text = text, FontSize = 12, MaxWidth = 240, TextTrimming = TextTrimming.CharacterEllipsis, Foreground = header ? Ui.Secondary : null },
        Padding = new Thickness(6, 3, 6, 3),
        BorderBrush = Ui.Divider,
        BorderThickness = new Thickness(0, 0, 1, 1),
        Background = header ? Ui.SubtleFill : null,
    };

    public static string ColumnName(int column)
    {
        var name = "";
        for (; column > 0; column = (column - 1) / 26) name = (char)('A' + (column - 1) % 26) + name;
        return name;
    }
}

/// <summary>
/// What changed between two versions of a file: paragraphs for text (Word, PowerPoint and PDF
/// included) with the changed words marked, cells for Excel, both pictures for images.
/// </summary>
public static class CompareView
{
    /// <param name="oldPath">The earlier version; null when the file didn't exist yet.</param>
    /// <param name="newPath">The later version; null when the file was deleted.</param>
    public static async Task<UIElement> CreateAsync(string? oldPath, string? newPath, string extension, string caption)
    {
        if (oldPath == null || newPath == null)
        {
            var message = oldPath == null
                ? Ui.Column(8, Ui.Icon(Glyph.Add, 36, Ui.Tertiary), Ui.Title(L.T("这是新添加的文件", "This File Is New"), 16),
                            Ui.Caption(L.T("之前没有这个文件，切到「预览」可以查看全部内容。", "There was no such file before. Switch to Preview to see all of it.")))
                : Ui.Column(8, Ui.Icon(Glyph.Delete, 36, Ui.Tertiary), Ui.Title(L.T("这个文件已被删除", "This File Was Deleted"), 16),
                            Ui.Caption(L.T("现在没有这个文件了。", "The file no longer exists.")));
            return WithHeader(caption, "", PreviewView.Centered(message));
        }

        if (ContentExtractor.ImageTypes.Contains(extension)) return WithHeader(caption, L.T("左边是之前，右边是现在", "Before on the left, now on the right"), Images(oldPath, newPath));

        var (before, after) = (await ContentExtractor.LoadAsync(oldPath, extension), await ContentExtractor.LoadAsync(newPath, extension));
        if (before.Kind == ContentKind.Sheets && after.Kind == ContentKind.Sheets)
        {
            var changes = await Task.Run(() => SheetDiff.Compare(before.Sheets ?? [], after.Sheets ?? []));
            return WithHeader(caption, changes.Count == 0 ? L.T("单元格内容没有变化", "No cell changes") : L.T($"改动 {changes.Count} 个单元格", $"{changes.Count} cells changed"),
                              changes.Count == 0 ? NoChanges() : SheetChanges(changes));
        }
        if (before.Kind is ContentKind.Text or ContentKind.Pdf && after.Kind is ContentKind.Text or ContentKind.Pdf)
        {
            var lines = await Task.Run(() => TextDiff.Compare(before.Text, after.Text));
            return new TextComparison(lines, caption).Element;
        }
        return WithHeader(caption, "", PreviewView.Centered(Ui.Column(8, Ui.Icon(Glyph.Question, 36, Ui.Tertiary),
            Ui.Caption(L.T("无法逐处对比这种文件", "This kind of file can't be compared change by change")),
            Ui.Caption(L.T($"大小：{Ui.Bytes(before.Size)} → {Ui.Bytes(after.Size)}", $"Size: {Ui.Bytes(before.Size)} → {Ui.Bytes(after.Size)}")))));
    }

    public static Grid WithHeader(string caption, string detail, UIElement body, UIElement? trailing = null)
    {
        var grid = Ui.Grid(rows: "auto,auto,*");
        var header = Ui.Grid("*,auto");
        header.Padding = new Thickness(14, 8, 14, 8);
        var lines = Ui.Column(1, Ui.Caption(caption));
        if (detail.Length > 0) lines.Children.Add(Ui.Text(detail, 13, FontWeights.SemiBold));
        header.Children.Add(lines.At(0, 0));
        if (trailing is FrameworkElement t) header.Children.Add(t.At(0, 1));
        grid.Children.Add(header.At(0));
        grid.Children.Add(new Border { Height = 1, Background = Ui.Divider }.At(1));
        if (body is FrameworkElement b) grid.Children.Add(b.At(2));
        return grid;
    }

    static UIElement NoChanges() => PreviewView.Centered(Ui.Column(8, Ui.Icon(Glyph.Check, 36, Ui.Tertiary), Ui.Title(L.T("没有改动", "No Changes"), 16),
        Ui.Caption(L.T("可能只改了格式、批注或图表。", "Only formatting, comments or charts may have changed."))));

    static UIElement SheetChanges(List<SheetDiff.Change> changes)
    {
        var grid = Ui.Grid("100,70,*,*");
        grid.ColumnSpacing = 12;
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        string[] headers = [L.T("工作表", "Sheet"), L.T("单元格", "Cell"), L.T("原来", "Before"), L.T("现在", "Now")];
        for (var c = 0; c < 4; c++) grid.Children.Add(Ui.Caption(headers[c]).At(0, c));
        var row = 1;
        foreach (var change in changes.Take(2000))
        {
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            grid.Children.Add(Ui.Text(change.Sheet, 12).At(row, 0));
            grid.Children.Add(Ui.Text(change.Cell, 12).At(row, 1));
            var before = Ui.Text(change.Old ?? "—", 12, brush: change.Old == null ? Ui.Secondary : Ui.Red);
            if (change.Old != null) before.TextDecorations = Windows.UI.Text.TextDecorations.Strikethrough;
            grid.Children.Add(before.At(row, 2));
            grid.Children.Add(Ui.Text(change.New ?? L.T("（已清空）", "(cleared)"), 12, brush: change.New == null ? Ui.Secondary : Ui.Green).At(row, 3));
            row++;
        }
        return new ScrollViewer { Content = grid, Padding = new Thickness(14, 8, 14, 8) };
    }

    static UIElement Images(string oldPath, string newPath)
    {
        Image Picture(string path) => new() { Source = new BitmapImage(new Uri(path)), Stretch = Stretch.Uniform };
        var grid = Ui.Grid("*,*", "auto,*");
        grid.ColumnSpacing = 12;
        grid.Padding = new Thickness(14);
        grid.Children.Add(Ui.Caption(L.T("之前", "Before")).At(0, 0));
        grid.Children.Add(Ui.Caption(L.T("现在", "Now")).At(0, 1));
        grid.Children.Add(Picture(oldPath).At(1, 0));
        grid.Children.Add(Picture(newPath).At(1, 1));
        return grid;
    }

    /// <summary>Changed paragraphs with a little context; long unchanged runs fold away.</summary>
    sealed class TextComparison
    {
        const int Context = 2;
        readonly List<TextDiff.Line> lines;
        readonly string caption;
        readonly HashSet<int> expanded = [];
        readonly StackPanel body = new() { Padding = new Thickness(0, 8, 0, 8) };
        readonly ScrollViewer scroller;
        readonly List<int> changeStarts;
        readonly Dictionary<int, FrameworkElement> anchors = [];
        int current;
        public Grid Element { get; }

        public TextComparison(List<TextDiff.Line> lines, string caption)
        {
            this.lines = lines;
            this.caption = caption;
            changeStarts = Enumerable.Range(0, lines.Count).Where(i => lines[i].IsChange && (i == 0 || !lines[i - 1].IsChange)).ToList();
            scroller = new ScrollViewer { Content = body };
            var summary = TextDiff.Summarize(lines);
            UIElement? navigation = null;
            if (changeStarts.Count > 1)
                navigation = Ui.Row(2, Ui.IconButton("", L.T("上一处改动", "Previous change"), () => Step(-1), 12),
                                       Ui.IconButton("", L.T("下一处改动", "Next change"), () => Step(1), 12));
            Element = WithHeader(caption, Summary(summary), summary.Total == 0 ? Unchanged() : scroller, navigation);
            if (summary.Total > 0) Render();
        }

        static UIElement Unchanged() => PreviewView.Centered(Ui.Column(8, Ui.Icon(Glyph.Check, 36, Ui.Tertiary), Ui.Title(L.T("没有改动", "No Changes"), 16),
            Ui.Caption(L.T("文字和上一个时间节点完全一样。如果文件确实改过，可能只改了格式、图片等无法比较文字的地方。",
                           "The text is the same as at the previous sync point. If the file did change, only formatting or pictures changed."), wrap: true)));

        string Summary(TextDiff.Summary summary)
        {
            if (summary.Total == 0) return L.T("没有文字改动", "No text changes");
            var parts = new List<string>();
            if (summary.Changed > 0) parts.Add(L.T($"修改 {summary.Changed} 段", $"{summary.Changed} edited"));
            if (summary.Added > 0) parts.Add(L.T($"新增 {summary.Added} 段", $"{summary.Added} added"));
            if (summary.Removed > 0) parts.Add(L.T($"删除 {summary.Removed} 段", $"{summary.Removed} removed"));
            return L.T($"改动 {changeStarts.Count} 处：", $"{changeStarts.Count} changes: ") + string.Join(" · ", parts);
        }

        void Step(int delta)
        {
            if (changeStarts.Count == 0) return;
            current = (current + delta + changeStarts.Count) % changeStarts.Count;
            if (anchors.TryGetValue(changeStarts[current], out var element)) element.StartBringIntoView(new BringIntoViewOptions { VerticalAlignmentRatio = 0.3 });
        }

        void Render()
        {
            body.Children.Clear();
            anchors.Clear();
            var keep = new HashSet<int>();
            for (var i = 0; i < lines.Count; i++)
                if (lines[i].IsChange)
                    for (var near = Math.Max(0, i - Context); near <= Math.Min(lines.Count - 1, i + Context); near++) keep.Add(near);
            for (var index = 0; index < lines.Count;)
            {
                if (keep.Contains(index)) { AddLine(index); index++; continue; }
                var end = index;
                while (end < lines.Count && !keep.Contains(end)) end++;
                if (end - index <= 3 || expanded.Contains(index))
                {
                    for (var i = index; i < end; i++) AddLine(i);
                }
                else
                {
                    var start = index;
                    var fold = new Button
                    {
                        Content = Ui.Caption(L.T($"… {end - index} 段未改动，点击展开 …", $"… {end - index} unchanged paragraphs, click to show …")),
                        HorizontalAlignment = HorizontalAlignment.Stretch, Background = Ui.SubtleFill, BorderThickness = new Thickness(0),
                    };
                    fold.Click += (_, _) => { expanded.Add(start); Render(); };
                    body.Children.Add(fold);
                }
                index = end;
            }
        }

        void AddLine(int index)
        {
            FrameworkElement element = lines[index] switch
            {
                TextDiff.Line.Same same => Row(Plain(same.Text), " ", null),
                TextDiff.Line.Added added => Row(Plain(added.Text), "+", Ui.Green),
                TextDiff.Line.Removed removed => Row(Plain(removed.Text, strike: true), "−", Ui.Red),
                TextDiff.Line.Changed changed => Ui.Column(0, Row(Marked(changed.Old, Ui.Red, strike: true), "−", Ui.Red, faint: true),
                                                              Row(Marked(changed.New, Ui.Green, strike: false), "+", Ui.Green, faint: true)),
                _ => new Border(),
            };
            anchors[index] = element;
            body.Children.Add(element);
        }

        static Grid Row(TextBlock text, string marker, SolidColorBrush? tint, bool faint = false)
        {
            var grid = Ui.Grid("20,*");
            grid.Padding = new Thickness(12, 2, 12, 2);
            if (tint != null) grid.Background = Ui.Tint(tint, (byte)(faint ? 16 : 30));
            grid.Children.Add(new TextBlock { Text = marker, FontFamily = new FontFamily("Consolas"), FontWeight = FontWeights.Bold, Foreground = tint ?? Ui.Secondary }.At(0, 0));
            text.TextWrapping = TextWrapping.Wrap;
            text.IsTextSelectionEnabled = true;
            text.FontSize = 13.5;
            grid.Children.Add(text.At(0, 1));
            return grid;
        }

        static TextBlock Plain(string text, bool strike = false)
        {
            var block = new TextBlock { Text = text };
            if (strike) block.TextDecorations = Windows.UI.Text.TextDecorations.Strikethrough;
            return block;
        }

        static TextBlock Marked(IReadOnlyList<TextDiff.Segment> segments, SolidColorBrush color, bool strike)
        {
            var block = new TextBlock();
            foreach (var segment in segments)
            {
                var run = new Run { Text = segment.Text };
                if (segment.Changed)
                {
                    run.Foreground = color;
                    run.FontWeight = FontWeights.SemiBold;
                    if (strike) run.TextDecorations = Windows.UI.Text.TextDecorations.Strikethrough;
                    else run.TextDecorations = Windows.UI.Text.TextDecorations.Underline;
                }
                block.Inlines.Add(run);
            }
            return block;
        }
    }
}
