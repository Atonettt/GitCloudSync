using System.Text;
using DocumentFormat.OpenXml.Packaging;
using GitSync.Core;
using UglyToad.PdfPig;
using UglyToad.PdfPig.DocumentLayoutAnalysis.TextExtractor;
using W = DocumentFormat.OpenXml.Wordprocessing;
using S = DocumentFormat.OpenXml.Spreadsheet;
using D = DocumentFormat.OpenXml.Drawing;

namespace GitSync.App.Services;

public enum ContentKind { Text, Sheets, Image, Pdf, Opaque }

/// <summary>What can be read out of a file for previewing and comparing.</summary>
public sealed record FileContent(ContentKind Kind, string Text = "", Dictionary<string, Dictionary<string, string>>? Sheets = null,
                                 long Size = 0, bool IsDocument = false);

/// <summary>
/// Reads text from plain text, Word, PowerPoint and PDF files, cell values from Excel workbooks,
/// and recognises images. Runs off the UI thread; files are only read.
/// </summary>
public static class ContentExtractor
{
    static ContentExtractor() => Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);

    public static readonly HashSet<string> ImageTypes = new(StringComparer.OrdinalIgnoreCase)
        { ".png", ".jpg", ".jpeg", ".gif", ".bmp", ".tif", ".tiff", ".ico", ".webp", ".heic" };
    static readonly HashSet<string> WordTypes = new(StringComparer.OrdinalIgnoreCase) { ".docx", ".docm", ".dotx", ".dotm" };
    static readonly HashSet<string> SheetTypes = new(StringComparer.OrdinalIgnoreCase) { ".xlsx", ".xlsm", ".xltx" };
    static readonly HashSet<string> SlideTypes = new(StringComparer.OrdinalIgnoreCase) { ".pptx", ".pptm", ".potx" };

    /// <param name="extension">The file's own extension (exported versions keep it).</param>
    public static Task<FileContent> LoadAsync(string path, string extension) => Task.Run(() => Load(path, extension));

    static FileContent Load(string path, string extension)
    {
        long size = 0;
        try { size = new FileInfo(path).Length; } catch { }
        try
        {
            if (ImageTypes.Contains(extension)) return new FileContent(ContentKind.Image, Size: size);
            if (extension.Equals(".pdf", StringComparison.OrdinalIgnoreCase))
            {
                var text = PdfText(path);
                return new FileContent(text.Trim().Length > 0 ? ContentKind.Pdf : ContentKind.Opaque, text, Size: size, IsDocument: true);
            }
            if (WordTypes.Contains(extension)) return new FileContent(ContentKind.Text, WordText(path), Size: size, IsDocument: true);
            if (SlideTypes.Contains(extension)) return new FileContent(ContentKind.Text, SlideText(path), Size: size, IsDocument: true);
            if (SheetTypes.Contains(extension)) return new FileContent(ContentKind.Sheets, Sheets: SheetCells(path), Size: size, IsDocument: true);
            if (extension.Equals(".rtf", StringComparison.OrdinalIgnoreCase) && PlainText(path) is { } rtf)
                return new FileContent(ContentKind.Text, StripRtf(rtf), Size: size, IsDocument: true);
            if (PlainText(path) is { } plain) return new FileContent(ContentKind.Text, plain, Size: size);
        }
        catch
        {
            // Damaged or password-protected: nothing to read.
        }
        return new FileContent(ContentKind.Opaque, Size: size);
    }

    /// <summary>Text files of any extension: no NUL bytes near the start, and decodable.</summary>
    static string? PlainText(string path)
    {
        var info = new FileInfo(path);
        if (!info.Exists || info.Length > 20_000_000) return null;
        var data = File.ReadAllBytes(path);
        if (data.AsSpan(0, Math.Min(8000, data.Length)).Contains((byte)0)) return null;
        try
        {
            return new UTF8Encoding(false, throwOnInvalidBytes: true).GetString(data).TrimStart('﻿');
        }
        catch (DecoderFallbackException)
        {
            return Encoding.GetEncoding(54936).GetString(data);   // GB18030: Chinese text saved by older Windows tools
        }
    }

    static string WordText(string path)
    {
        using var document = WordprocessingDocument.Open(path, false);
        var body = document.MainDocumentPart?.Document?.Body;
        if (body == null) return "";
        return string.Join("\n", body.Descendants<W.Paragraph>().Select(p => p.InnerText));
    }

    static string SlideText(string path)
    {
        using var document = PresentationDocument.Open(path, false);
        var builder = new StringBuilder();
        var slideIds = document.PresentationPart?.Presentation?.SlideIdList?.Elements<DocumentFormat.OpenXml.Presentation.SlideId>() ?? [];
        var number = 1;
        foreach (var id in slideIds)
        {
            if (document.PresentationPart!.GetPartById(id.RelationshipId!) is not SlidePart slide) continue;
            builder.AppendLine(L.T($"— 第 {number++} 页 —", $"— Slide {number++} —"));
            foreach (var paragraph in slide.Slide.Descendants<D.Paragraph>())
                builder.AppendLine(string.Concat(paragraph.Descendants<D.Text>().Select(t => t.Text)));
        }
        return builder.ToString();
    }

    /// <summary>The shown value of every cell, per sheet (cached results for formulas).</summary>
    public static Dictionary<string, Dictionary<string, string>> SheetCells(string path)
    {
        using var document = SpreadsheetDocument.Open(path, false);
        var workbook = document.WorkbookPart!;
        var shared = workbook.SharedStringTablePart?.SharedStringTable?.Elements<S.SharedStringItem>().Select(i => i.InnerText).ToList() ?? [];
        var result = new Dictionary<string, Dictionary<string, string>>();
        foreach (var sheet in workbook.Workbook.Sheets?.Elements<S.Sheet>() ?? [])
        {
            if (sheet.Id?.Value is not { } id || workbook.GetPartById(id) is not WorksheetPart part) continue;
            var cells = new Dictionary<string, string>();
            foreach (var cell in part.Worksheet.Descendants<S.Cell>())
            {
                var reference = cell.CellReference?.Value;
                if (reference == null) continue;
                var value = cell.CellValue?.Text ?? cell.InlineString?.InnerText ?? "";
                if (cell.DataType?.Value == S.CellValues.SharedString && int.TryParse(value, out var index) && index < shared.Count)
                    value = shared[index];
                else if (cell.DataType?.Value == S.CellValues.Boolean)
                    value = value == "1" ? "TRUE" : "FALSE";
                if (value.Length > 0) cells[reference] = value;
            }
            result[sheet.Name?.Value ?? id] = cells;
        }
        return result;
    }

    static string PdfText(string path)
    {
        using var document = PdfDocument.Open(path);
        return string.Join("\n", document.GetPages().Select(page => ContentOrderTextExtractor.GetText(page)));
    }

    /// <summary>Rough RTF to text: enough to compare paragraphs.</summary>
    static string StripRtf(string rtf)
    {
        var text = System.Text.RegularExpressions.Regex.Replace(rtf, @"\\par[d]?", "\n");
        text = System.Text.RegularExpressions.Regex.Replace(text, @"\{\\\*[^{}]*\}|\\[a-z]+-?\d* ?|[{}]", "");
        return text;
    }
}
