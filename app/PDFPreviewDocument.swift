import PDFKit

final class PDFPreviewDocument: WorkspaceDocument {
    private(set) var location: URL
    func relocate(to url:URL) { location = url }
    var url: URL? { location }
    var title: String { location.lastPathComponent }
    let dirty = false
    private(set) lazy var view: PDFView = {
        let viewer = PDFView()
        viewer.autoScales = true
        viewer.displayMode = .singlePageContinuous
        return viewer
    }()
    private var visible = false
    private var pageIndex = 0
    private var revision: FileRevision?
    var status: String { view.document == nil ? L("Unable to read PDF") : L("PDF Preview") }

    init(_ url:URL) { location = url }

    func show() {
        visible = true
        reconcile()
    }

    private func rememberPage() {
        if let document = view.document, let page = view.currentPage { pageIndex = document.index(for:page) }
    }

    func hide() {
        rememberPage()
        visible = false
        view.document = nil
        revision = nil
    }

    func reconcile() {
        guard visible else { return }
        let current = try? FileRevision(location)
        guard revision != current else { return }
        rememberPage()
        revision = current
        view.document = current.flatMap { _ in PDFDocument(url:location) }
        if let document = view.document, document.pageCount > 0,
           let page = document.page(at:min(pageIndex,document.pageCount-1)) { view.go(to:page) }
    }
}
