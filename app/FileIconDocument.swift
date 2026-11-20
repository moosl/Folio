import AppKit
import UniformTypeIdentifiers

final class FileIconDocument: WorkspaceDocument {
    let location: URL
    var url: URL? { location }
    var title: String { location.lastPathComponent }
    let dirty = false

    init(_ url:URL) { location = url }
    func reconcile() {}

    static func prefersIcon(_ url:URL) -> Bool {
        guard let type = UTType(filenameExtension:url.pathExtension), !type.conforms(to:.text) else { return false }
        // Other type identifiers can be ambiguous: .ts is also used for MPEG transport streams.
        // Let the text reader inspect those files before falling back to their icon.
        return type.conforms(to:.pdf) || type.conforms(to:.archive)
    }

    func makeView() -> NSView {
        let icon = NSImageView(image:NSWorkspace.shared.icon(forFile:location.path))
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.width(128); icon.height(128)
        let name = label(title,16,Ink.text,.medium)
        name.toolTip = title
        let column = stack(.vertical,[icon,name],12)
        column.alignment = .centerX
        let view = NSView()
        view.addSubview(column)
        column.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([column.centerXAnchor.constraint(equalTo:view.centerXAnchor),
            column.centerYAnchor.constraint(equalTo:view.centerYAnchor),
            column.widthAnchor.constraint(lessThanOrEqualTo:view.widthAnchor)])
        return view
    }
}
