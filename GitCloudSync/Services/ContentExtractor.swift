import AppKit
import PDFKit

/// Reads what can be compared out of a file: its text (plain text, Word, RTF, PDF…), the cell
/// values of an Excel workbook, or an image. Runs off the main thread; nothing is written back.
enum ComparableContent {
    case text(String)
    case sheets([String: [String: String]])
    case image(NSImage)
    /// Nothing to compare inside (an archive, a scanned PDF without text…); only the size is known.
    case opaque(Int64)

    static let imageTypes: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "heif", "tif", "tiff", "bmp", "webp"]
    /// Converted to plain text by macOS's `textutil`.
    static let documentTypes: Set<String> = ["doc", "docx", "dot", "dotx", "docm", "rtf", "rtfd", "odt", "wordml", "html", "htm", "webarchive"]
    static let sheetTypes: Set<String> = ["xlsx", "xlsm"]

    /// The content of `url`, judged by its extension (`kind`) since exported versions keep the
    /// original name only in the extension.
    static func load(_ url: URL, kind: String) async -> ComparableContent {
        await Task.detached(priority: .userInitiated) { () -> ComparableContent in
            let ext = kind.lowercased()
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            if imageTypes.contains(ext), let image = NSImage(contentsOf: url) { return .image(image) }
            if ext == "pdf" {
                guard let text = PDFDocument(url: url)?.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return .opaque(size) }
                return .text(text)
            }
            if documentTypes.contains(ext) {
                return textutil(url).map(ComparableContent.text) ?? .opaque(size)
            }
            if sheetTypes.contains(ext) {
                return XLSXReader.read(url).map(ComparableContent.sheets) ?? .opaque(size)
            }
            if ext == "pages", let text = textutil(url) { return .text(text) }
            return plainText(url).map(ComparableContent.text) ?? .opaque(size)
        }.value
    }

    /// Text files of any extension: no NUL bytes in the start, and decodable.
    private static func plainText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count < 20_000_000 else { return nil }
        if data.prefix(8000).contains(0) { return nil }
        if let text = String(data: data, encoding: .utf8) { return text }
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        return String(data: data, encoding: gb18030) ?? String(data: data, encoding: .utf16)
    }

    private static func textutil(_ url: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        process.arguments = ["-convert", "txt", "-encoding", "UTF-8", "-stdout", url.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// The shown values of every cell in an .xlsx workbook (cached results for formulas).
enum XLSXReader {
    static func read(_ url: URL) -> [String: [String: String]]? {
        guard let workbook = entry("xl/workbook.xml", in: url),
              let relations = entry("xl/_rels/workbook.xml.rels", in: url) else { return nil }
        let sheets = Elements.collect(workbook, named: "sheet")
        let targets = Dictionary(Elements.collect(relations, named: "Relationship").compactMap { attributes -> (String, String)? in
            guard let id = attributes["Id"], let target = attributes["Target"] else { return nil }
            return (id, target)
        }, uniquingKeysWith: { first, _ in first })
        let shared = entry("xl/sharedStrings.xml", in: url).map(SharedStrings.parse) ?? []

        var result: [String: [String: String]] = [:]
        for sheet in sheets {
            guard let name = sheet["name"], let id = sheet["r:id"], var target = targets[id] else { continue }
            if target.hasPrefix("/") { target.removeFirst() } else { target = "xl/" + target }
            guard let data = entry(target, in: url) else { continue }
            result[name] = Cells.parse(data, shared: shared)
        }
        return result
    }

    /// One file from inside the .xlsx (a zip archive), read with the system's unzip.
    private static func entry(_ path: String, in archive: URL) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", archive.path, path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 && !data.isEmpty ? data : nil
    }

    /// Attributes of every element with a given name.
    private final class Elements: NSObject, XMLParserDelegate {
        let name: String
        var found: [[String: String]] = []
        init(name: String) { self.name = name }

        static func collect(_ data: Data, named name: String) -> [[String: String]] {
            let delegate = Elements(name: name)
            let parser = XMLParser(data: data)
            parser.delegate = delegate
            parser.parse()
            return delegate.found
        }

        func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            if element == name { found.append(attributes) }
        }
    }

    /// The shared string table: one entry per <si>, joining rich-text runs.
    private final class SharedStrings: NSObject, XMLParserDelegate {
        var strings: [String] = []
        var current: String?
        var inText = false

        static func parse(_ data: Data) -> [String] {
            let delegate = SharedStrings()
            let parser = XMLParser(data: data)
            parser.delegate = delegate
            parser.parse()
            return delegate.strings
        }

        func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            if element == "si" { current = "" }
            if element == "t" { inText = true }
            // Phonetic hints (<rPh>) are not part of the shown text.
            if element == "rPh" { inText = false }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inText { current? += string }
        }

        func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
            if element == "t" { inText = false }
            if element == "si" { strings.append(current ?? ""); current = nil }
        }
    }

    /// Cell values of one worksheet.
    private final class Cells: NSObject, XMLParserDelegate {
        let shared: [String]
        var cells: [String: String] = [:]
        var reference: String?
        var type: String?
        var value = ""
        var reading = false

        init(shared: [String]) { self.shared = shared }

        static func parse(_ data: Data, shared: [String]) -> [String: String] {
            let delegate = Cells(shared: shared)
            let parser = XMLParser(data: data)
            parser.delegate = delegate
            parser.parse()
            return delegate.cells
        }

        func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            switch element {
            case "c":
                reference = attributes["r"]
                type = attributes["t"]
                value = ""
            case "v", "t":
                reading = reference != nil
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if reading { value += string }
        }

        func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
            switch element {
            case "v", "t":
                reading = false
            case "c":
                if let reference, !value.isEmpty {
                    switch type {
                    case "s": cells[reference] = Int(value).flatMap { shared.indices.contains($0) ? shared[$0] : nil } ?? value
                    case "b": cells[reference] = value == "1" ? "TRUE" : "FALSE"
                    default: cells[reference] = value
                    }
                }
                reference = nil
            default:
                break
            }
        }
    }
}
