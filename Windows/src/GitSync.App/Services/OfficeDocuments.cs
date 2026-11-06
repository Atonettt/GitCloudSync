using System.Runtime.InteropServices;
using GitSync.Core;

namespace GitSync.App.Services;

/// <summary>
/// Word, Excel and PowerPoint keep a document in memory and never notice when the file changes on
/// disk; on Windows they also lock the file, so a sync can't replace it while it's open. These
/// helpers talk to the running Office apps through COM to find, close and reopen documents.
/// </summary>
public static class OfficeDocuments
{
    public sealed record OfficeApp(string Name, string ProgId, string Collection);

    public static readonly OfficeApp Word = new("Word", "Word.Application", "Documents");
    public static readonly OfficeApp Excel = new("Excel", "Excel.Application", "Workbooks");
    public static readonly OfficeApp PowerPoint = new("PowerPoint", "PowerPoint.Application", "Presentations");
    public static readonly OfficeApp[] Apps = [Word, Excel, PowerPoint];

    public sealed record OpenDocument(OfficeApp App, string Path, bool Saved)
    {
        public string FileName => System.IO.Path.GetFileName(Path);
    }

    static readonly HashSet<string> OfficeExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        ".doc", ".docx", ".docm", ".dot", ".dotx", ".rtf", ".xls", ".xlsx", ".xlsm", ".xlsb", ".csv", ".ppt", ".pptx", ".pptm",
    };

    public static bool IsOfficeFile(string path) => OfficeExtensions.Contains(System.IO.Path.GetExtension(path));

    /// <summary>
    /// Office writes a "~$" owner file next to every open document ("~$" plus the name, or replacing
    /// the first two characters of a long name). Checking it first means Office is only asked when
    /// a file is really open.
    /// </summary>
    public static bool ProbablyOpen(string path)
    {
        var name = System.IO.Path.GetFileName(path);
        var folder = System.IO.Path.GetDirectoryName(path) ?? "";
        string[] candidates = ["~$" + name, name.Length > 2 ? "~$" + name[2..] : "", name.Length > 1 ? "~$" + name[1..] : ""];
        return candidates.Any(c => c.Length > 2 && File.Exists(System.IO.Path.Combine(folder, c)));
    }

    /// <summary>Documents open in a running Office app whose file is one of the given paths.</summary>
    public static List<OpenDocument> OpenDocuments(IEnumerable<string> paths)
    {
        var wanted = paths.Select(Normalize).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var documents = new List<OpenDocument>();
        if (wanted.Count == 0) return documents;
        foreach (var app in Apps)
        {
            if (Running(app) is not { } application) continue;
            try
            {
                foreach (var document in Items(application, app))
                {
                    string fullName = document.FullName;
                    if (!wanted.Contains(Normalize(fullName))) continue;
                    documents.Add(new OpenDocument(app, fullName, IsSaved(app, document)));
                }
            }
            catch (COMException) { /* the app is busy (a dialog is open) */ }
        }
        return documents;
    }

    /// <summary>Every document open in Office that lives inside a folder.</summary>
    public static List<OpenDocument> OpenDocumentsInside(string folder)
    {
        var prefix = Normalize(folder).TrimEnd('\\') + "\\";
        var documents = new List<OpenDocument>();
        foreach (var app in Apps)
        {
            if (Running(app) is not { } application) continue;
            try
            {
                foreach (var document in Items(application, app))
                {
                    string fullName = document.FullName;
                    if (Normalize(fullName).StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
                        documents.Add(new OpenDocument(app, fullName, IsSaved(app, document)));
                }
            }
            catch (COMException) { }
        }
        return documents;
    }

    /// <summary>Closes the document without saving. Returns an error message, or null.</summary>
    public static string? Close(OpenDocument target)
    {
        try
        {
            var document = Find(target) ?? throw new InvalidOperationException(L.T("文档已经关闭", "The document is already closed"));
            if (target.App == PowerPoint) document.Close();          // PowerPoint closes without asking
            else if (target.App == Excel) document.Close(false);
            else document.Close(0);                                   // wdDoNotSaveChanges
            return null;
        }
        catch (Exception error)
        {
            return error.Message;
        }
    }

    /// <summary>Opens the file again in the same Office app.</summary>
    public static void Open(OpenDocument target)
    {
        try
        {
            if (Running(target.App) is { } application)
            {
                dynamic collection = Collection(application, target.App);
                collection.Open(target.Path);
                return;
            }
        }
        catch { /* fall back to the default app */ }
        Shell.Open(target.Path);
    }

    /// <summary>Closes and reopens, so the document shows what's on disk now.</summary>
    public static string? Reopen(OpenDocument target)
    {
        if (Close(target) is { } problem) return problem;
        Open(target);
        return null;
    }

    /// <summary>Saves the document's edits under another name (it stays open as that file), then opens the original.</summary>
    public static string? SaveCopyAndReopen(OpenDocument target, string copyPath)
    {
        try
        {
            var document = Find(target) ?? throw new InvalidOperationException(L.T("文档已经关闭", "The document is already closed"));
            if (target.App == Word) document.SaveAs2(copyPath);
            else document.SaveAs(copyPath);
            if (!File.Exists(copyPath)) return L.T($"{target.App.Name} 没有保存出副本", $"{target.App.Name} didn't save the copy");
            Open(target);
            return null;
        }
        catch (Exception error)
        {
            return error.Message;
        }
    }

    /// <summary>A free name next to the file, such as "报告（我的修改）.docx".</summary>
    public static string CopyPath(string path)
    {
        var folder = System.IO.Path.GetDirectoryName(path) ?? "";
        var stem = System.IO.Path.GetFileNameWithoutExtension(path);
        var ext = System.IO.Path.GetExtension(path);
        for (var index = 1; ; index++)
        {
            var label = index == 1 ? L.T("我的修改", "my changes") : L.T($"我的修改 {index}", $"my changes {index}");
            var candidate = System.IO.Path.Combine(folder, L.IsChinese ? $"{stem}（{label}）{ext}" : $"{stem} ({label}){ext}");
            if (!File.Exists(candidate)) return candidate;
        }
    }

    static dynamic? Find(OpenDocument target)
    {
        if (Running(target.App) is not { } application) return null;
        foreach (var document in Items(application, target.App))
        {
            string fullName = document.FullName;
            if (string.Equals(Normalize(fullName), Normalize(target.Path), StringComparison.OrdinalIgnoreCase)) return document;
        }
        return null;
    }

    static bool IsSaved(OfficeApp app, dynamic document)
    {
        try
        {
            object saved = document.Saved;
            // PowerPoint answers with MsoTriState (-1 = true).
            return saved is bool b ? b : Convert.ToInt32(saved) != 0;
        }
        catch
        {
            return false;   // unknown counts as unsaved, so edits are never thrown away silently
        }
    }

    static dynamic Collection(dynamic application, OfficeApp app) => app == Word ? application.Documents
        : app == Excel ? application.Workbooks : application.Presentations;

    static IEnumerable<dynamic> Items(dynamic application, OfficeApp app)
    {
        dynamic collection = Collection(application, app);
        int count = collection.Count;
        for (var index = 1; index <= count; index++) yield return collection.Item(index);
    }

    /// <summary>The running Office app, or null (never starts one).</summary>
    static dynamic? Running(OfficeApp app)
    {
        try
        {
            if (CLSIDFromProgID(app.ProgId, out var clsid) != 0) return null;
            if (GetActiveObject(ref clsid, 0, out var instance) != 0) return null;
            return instance;
        }
        catch
        {
            return null;
        }
    }

    static string Normalize(string path)
    {
        try { return System.IO.Path.GetFullPath(path).Normalize(); } catch { return path; }
    }

    [DllImport("ole32.dll", CharSet = CharSet.Unicode)]
    static extern int CLSIDFromProgID(string progId, out Guid clsid);

    [DllImport("oleaut32.dll")]
    static extern int GetActiveObject(ref Guid clsid, nint reserved, [MarshalAs(UnmanagedType.IUnknown)] out object instance);
}
