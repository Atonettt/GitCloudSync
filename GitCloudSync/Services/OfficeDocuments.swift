import AppKit

/// Word, Excel and PowerPoint keep a document's content in memory and never notice when the file
/// changes on disk. After a sync downloads a new version, these helpers find the affected open
/// documents (through AppleScript, which asks the user once for permission) and reopen them.
@MainActor
enum OfficeDocuments {
    struct OfficeApp: Hashable, Sendable {
        let name: String
        let bundleID: String
        /// The AppleScript element holding open documents. Word does not support
        /// `repeat with x in documents`, so the scripts fetch the list and loop by index.
        let collection: String
        /// Saves `theDoc` under `copyPath` (an AppleScript string), keeping the edits.
        let saveAsTemplate: String
    }

    static let word = OfficeApp(name: "Word", bundleID: "com.microsoft.Word", collection: "documents",
                                saveAsTemplate: "save as theDoc file name ((POSIX file %@) as string)")
    static let excel = OfficeApp(name: "Excel", bundleID: "com.microsoft.Excel", collection: "workbooks",
                                 saveAsTemplate: "save workbook as theDoc filename ((POSIX file %@) as string)")
    static let powerPoint = OfficeApp(name: "PowerPoint", bundleID: "com.microsoft.Powerpoint", collection: "presentations",
                                      saveAsTemplate: "save theDoc in (POSIX file %@)")
    static let apps = [word, excel, powerPoint]

    struct OpenDocument: Hashable, Sendable {
        let app: OfficeApp
        /// The name exactly as the app reports it, used to find the document again.
        let reportedName: String
        let path: String
        /// False when the document has edits that are not saved to disk.
        let saved: Bool
        var fileName: String { (path as NSString).lastPathComponent }
    }

    enum Problem: Error {
        /// The user did not allow GitSync to control the app (System Settings › Privacy › Automation).
        case notAllowed(String)
        case script(String)
    }

    /// Office writes a "~$" owner file next to every document it has open ("~$" plus the name, or
    /// replacing the first two characters of a long name). Checking for it first means GitSync only
    /// talks to Office — and macOS only asks for permission — when a downloaded file is really open.
    static func probablyOpen(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        let folder = url.deletingLastPathComponent()
        let candidates = ["~$" + name, "~$" + String(name.dropFirst(2)), "~$" + String(name.dropFirst(1))]
        return candidates.contains { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }

    /// The open documents among `paths` (absolute), in running Office apps only, so nothing is
    /// launched and no permission is asked for when no Office app is open.
    static func openDocuments(among paths: Set<String>) -> (documents: [OpenDocument], problems: [Problem]) {
        let wanted = Set(paths.map(normalize))
        var documents: [OpenDocument] = []
        var problems: [Problem] = []
        for app in apps where isRunning(app) {
            let script = """
            tell application id "\(app.bundleID)"
                set out to ""
                set docs to \(app.collection)
                repeat with i from 1 to (length of docs)
                    set theDoc to item i of docs
                    set docName to full name of theDoc
                    if docName starts with "/" then
                        set docPath to docName
                    else
                        set docPath to POSIX path of docName
                    end if
                    set isSaved to "?"
                    try
                        set isSaved to (saved of theDoc) as string
                    end try
                    set out to out & docName & tab & docPath & tab & isSaved & linefeed
                end repeat
                return out
            end tell
            """
            switch run(script) {
            case .success(let output):
                for line in output.split(separator: "\n") {
                    let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                    guard let name = parts.first, !name.isEmpty else { continue }
                    let reportedPath = parts.count > 1 && !parts[1].isEmpty ? parts[1] : posixPath(fromReported: name)
                    let path = normalize(reportedPath)
                    guard wanted.contains(path) else { continue }
                    // An unknown saved state counts as unsaved, so edits are never thrown away silently.
                    documents.append(OpenDocument(app: app, reportedName: name, path: path,
                                                  saved: parts.count > 2 && parts[2] == "true"))
                }
            case .failure(let problem):
                problems.append(problem)
            }
        }
        return (documents, problems)
    }

    /// Closes the document without saving and opens the file again, showing what is on disk now.
    static func reopen(_ document: OpenDocument) -> Problem? {
        if let problem = close(document) { return problem }
        open(document)
        return nil
    }

    /// Saves the document's edits as `copyPath`, then opens the downloaded file as well.
    static func saveCopyAndReopen(_ document: OpenDocument, copyPath: String) -> Problem? {
        let saveAs = String(format: document.app.saveAsTemplate, quoted(copyPath))
        let script = """
        tell application id "\(document.app.bundleID)"
            set docs to \(document.app.collection)
            repeat with i from 1 to (length of docs)
                set theDoc to item i of docs
                if (full name of theDoc) is \(quoted(document.reportedName)) then
                    \(saveAs)
                    exit repeat
                end if
            end repeat
        end tell
        """
        if case .failure(let problem) = run(script) { return problem }
        guard FileManager.default.fileExists(atPath: copyPath) else {
            return .script(String(localized: "\(document.app.name) 没有保存出副本"))
        }
        // After "save as" the window belongs to the copy; the downloaded file opens in its own window.
        open(document)
        return nil
    }

    /// A free name next to `path`, such as "报告（我的修改）.docx".
    static func copyPath(for path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let folder = url.deletingLastPathComponent()
        var index = 1
        while true {
            let label = index == 1 ? String(localized: "我的修改") : String(localized: "我的修改 \(index)")
            let name = "\(base)（\(label)）" + (ext.isEmpty ? "" : ".\(ext)")
            let candidate = folder.appendingPathComponent(name).path
            if !FileManager.default.fileExists(atPath: candidate) { return candidate }
            index += 1
        }
    }

    // MARK: - Helpers

    private static func close(_ document: OpenDocument) -> Problem? {
        let script = """
        tell application id "\(document.app.bundleID)"
            set docs to \(document.app.collection)
            repeat with i from 1 to (length of docs)
                set theDoc to item i of docs
                if (full name of theDoc) is \(quoted(document.reportedName)) then
                    close theDoc saving no
                    exit repeat
                end if
            end repeat
        end tell
        """
        if case .failure(let problem) = run(script) { return problem }
        return nil
    }

    private static func open(_ document: OpenDocument) {
        let file = URL(fileURLWithPath: document.path)
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: document.app.bundleID) else {
            NSWorkspace.shared.open(file)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.open([file], withApplicationAt: appURL, configuration: configuration)
    }

    private static func isRunning(_ app: OfficeApp) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).isEmpty
    }

    private static func run(_ source: String) -> Result<String, Problem> {
        guard let script = NSAppleScript(source: source) else { return .failure(.script("NSAppleScript")) }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let number = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            let message = (error[NSAppleScript.errorMessage] as? String) ?? String(describing: error)
            // -1743: not authorized to send Apple events; -1744: the user would need to consent.
            return .failure(number == -1743 || number == -1744 ? .notAllowed(message) : .script(message))
        }
        return .success(result.stringValue ?? "")
    }

    /// Office reports POSIX paths, but older versions use HFS paths ("Macintosh HD:Users:…").
    static func posixPath(fromReported name: String) -> String {
        if name.hasPrefix("/") { return name }
        let parts = name.split(separator: ":", omittingEmptySubsequences: false).dropFirst()
        return "/" + parts.joined(separator: "/")
    }

    private static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
            .precomposedStringWithCanonicalMapping
    }

    private static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
