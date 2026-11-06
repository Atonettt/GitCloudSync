import PDFKit
import Quartz
import SwiftUI
import WebKit

/// Quick Look's own preview view, embedded: documents, spreadsheets, PDFs, images, text, media.
///
/// Quick Look shows word-processing documents as a web page laid out at a fixed page width and
/// centred, so a wide pane gets big blank margins and a narrow one cuts the page off. For those
/// documents the page is zoomed to fill the pane's width instead (PDFs and images already fit).
struct QuickLookView: NSViewRepresentable {
    let url: URL
    /// Changes when the file on disk changes (for example after a sync downloaded a new version),
    /// so the preview reloads instead of showing what Quick Look read the first time.
    var revision: Date? = nil

    private static let pagedTypes: Set<String> = ["doc", "docx", "dot", "dotx", "rtf", "rtfd", "odt", "pages"]

    func makeNSView(context: Context) -> FitWidthPreviewView {
        let view = FitWidthPreviewView()
        view.show(url, fitWidth: fitsWidth, revision: revision)
        return view
    }

    func updateNSView(_ view: FitWidthPreviewView, context: Context) {
        view.show(url, fitWidth: fitsWidth, revision: revision)
    }

    static func dismantleNSView(_ view: FitWidthPreviewView, coordinator: ()) {
        // Not `close()`: Quick Look asserts (and aborts the app) when a preview that never got
        // activated — removed before it finished loading, or while its window was closing — is
        // closed. Dropping the item releases the preview; the view itself closes with its window.
        view.stop()
    }

    private var fitsWidth: Bool {
        Self.pagedTypes.contains(url.pathExtension.lowercased())
    }
}

/// Hosts the Quick Look view and keeps a web-rendered document zoomed to the available width.
/// PDFs are shown with PDFKit instead: Quick Look's embedded PDF view did not scroll here.
final class FitWidthPreviewView: NSView {
    let preview: QLPreviewView = {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.autostarts = true
        view.autoresizingMask = [.width, .height]
        return view
    }()

    /// Created the first time a PDF is shown.
    private var pdfView: PDFView?

    private var url: URL?
    private var revision: Date?
    private var fitWidth = false
    /// Width of the document page in CSS pixels, measured once it has loaded.
    private var contentWidth: CGFloat?
    private var generation = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        preview.frame = bounds
        addSubview(preview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func stop() {
        generation += 1          // cancels pending page measurements
        url = nil
        revision = nil
        preview.previewItem = nil
        pdfView?.document = nil
    }

    func show(_ url: URL, fitWidth: Bool, revision: Date? = nil) {
        let sameFile = url == self.url && fitWidth == self.fitWidth
        if sameFile, revision == self.revision { return }
        let reload = sameFile && self.revision != nil
        self.url = url
        self.fitWidth = fitWidth
        self.revision = revision
        contentWidth = nil
        generation += 1
        if url.pathExtension.lowercased() == "pdf" {
            showPDF(url)
            return
        }
        pdfView?.isHidden = true
        preview.isHidden = false
        if reload {
            // Same file, new content: have Quick Look read it again.
            preview.refreshPreviewItem()
        } else {
            preview.previewItem = url as NSURL
        }
        if fitWidth { measure(generation: generation, attempt: 0) }
    }

    override func layout() {
        super.layout()
        applyZoom()
    }

    private func showPDF(_ url: URL) {
        let view: PDFView
        if let pdfView {
            view = pdfView
        } else {
            view = PDFView(frame: bounds)
            view.autoresizingMask = [.width, .height]
            view.autoScales = true                         // fit the page width, follow resizing
            view.displayMode = .singlePageContinuous       // scroll through all pages
            view.displaysPageBreaks = true
            view.backgroundColor = .clear
            addSubview(view)
            pdfView = view
        }
        preview.previewItem = nil
        preview.isHidden = true
        view.isHidden = false
        view.document = PDFDocument(url: url)              // read again, so a downloaded version shows
        view.autoScales = true
    }

    /// Quick Look loads the document asynchronously, so the page width is read a few times until
    /// the page is there.
    private func measure(generation: Int, attempt: Int) {
        let delays: [TimeInterval] = [0.2, 0.4, 0.8, 1.5, 3]
        guard attempt < delays.count else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delays[attempt]) { [weak self] in
            guard let self, self.generation == generation, let web = self.webView else {
                self?.measure(generation: generation, attempt: attempt + 1)
                return
            }
            let script = "Math.max(0, ...Array.from(document.body ? document.body.children : []).map(e => e.scrollWidth))"
            web.evaluateJavaScript(script) { [weak self] result, _ in
                guard let self, self.generation == generation else { return }
                let width = (result as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
                if width > 0 {
                    self.contentWidth = width
                    self.applyZoom()
                } else {
                    self.measure(generation: generation, attempt: attempt + 1)
                }
            }
        }
    }

    private func applyZoom() {
        guard fitWidth, let contentWidth, let web = webView, bounds.width > 0 else { return }
        // The page sits inside the body's default 8 px margins; leave room for those and the scroll bar.
        let zoom = min(2.5, max(0.25, (bounds.width - 20) / (contentWidth + 24)))
        if abs(web.pageZoom - zoom) > 0.005 { web.pageZoom = zoom }
    }

    private var webView: WKWebView? {
        func find(_ view: NSView) -> WKWebView? {
            if let web = view as? WKWebView { return web }
            for child in view.subviews {
                if let web = find(child) { return web }
            }
            return nil
        }
        return find(preview)
    }
}
