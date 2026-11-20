import AppKit

func rgb(_ hex: Int, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 255)/255, green: CGFloat(hex >> 8 & 255)/255,
            blue: CGFloat(hex & 255)/255, alpha: alpha)
}
func dual(_ light: Int, _ dark: Int, _ alpha: CGFloat = 1) -> NSColor {
    let day = rgb(light,alpha), night = rgb(dark,alpha)
    return NSColor(name:nil) { $0.bestMatch(from:[.aqua,.darkAqua]) == .darkAqua ? night : day }
}
// Warm paper by day, lamplit study by night.
enum Ink {
    static let rail = dual(0xf3eee6, 0x191613), canvas = dual(0xfbf8f3, 0x1f1b18)
    static let card = dual(0xf1ebe2, 0x2a2521), raised = dual(0xffffff, 0x27221e)
    static let line = dual(0xe7dfd3, 0x352f2a), text = dual(0x2f2a25, 0xede6dc)
    static let muted = dual(0x7c7268, 0xa99e92), faint = dual(0xaaa094, 0x786f66)
    static let accent = dual(0xbf6a3f, 0xe2a571), wash = dual(0xbf6a3f, 0xe2a571, 0.13)
    static let shadow = dual(0x5a4630, 0x000000, 0.10)
    static let warn = dual(0xb7792a, 0xe2bb81), warnWash = dual(0xf8ecd6, 0x3a3025)
}
/// Layer-backed fill that re-resolves its dynamic colors when the appearance changes.
final class Surface: NSView {
    var fill: NSColor { didSet { needsDisplay = true } }
    var border: NSColor? { didSet { needsDisplay = true } }
    var lift = false { didSet { needsDisplay = true } }
    init(_ fill: NSColor, radius: CGFloat) {
        self.fill = fill
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        guard let layer else { return }
        layer.backgroundColor = fill.cgColor
        layer.borderColor = border?.cgColor
        layer.borderWidth = border == nil ? 0 : 1
        layer.shadowColor = lift ? Ink.shadow.cgColor : nil
        layer.shadowOpacity = lift ? 1 : 0
        layer.shadowRadius = 10
        layer.shadowOffset = NSSize(width: 0, height: -3)
        layer.masksToBounds = false
    }
}
func surface(_ color: NSColor, radius: CGFloat = 0) -> Surface { Surface(color, radius: radius) }
func label(_ value: String, _ size: CGFloat = 13, _ color: NSColor = Ink.text,
           _ weight: NSFont.Weight = .regular) -> NSTextField {
    let v = NSTextField(labelWithString: value)
    v.font = .systemFont(ofSize: size, weight: weight)
    v.textColor = color
    v.lineBreakMode = .byTruncatingMiddle
    v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return v
}
func serif(_ size: CGFloat, _ weight: NSFont.Weight = .semibold) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    return base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } ?? base
}
func stack(_ axis: NSUserInterfaceLayoutOrientation, _ views: [NSView] = [], _ spacing: CGFloat = 0) -> NSStackView {
    let s = NSStackView(views: views)
    s.orientation = axis
    s.spacing = spacing
    s.alignment = axis == .vertical ? .leading : .centerY
    s.detachesHiddenViews = true
    return s
}
extension NSView {
    func pin(_ child: NSView, _ inset: NSEdgeInsets = NSEdgeInsetsZero) {
        addSubview(child)
        child.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset.left),
            child.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset.right),
            child.topAnchor.constraint(equalTo: topAnchor, constant: inset.top),
            child.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset.bottom)
        ])
    }
    func height(_ n: CGFloat) { heightAnchor.constraint(equalToConstant: n).isActive = true }
    func width(_ n: CGFloat) { widthAnchor.constraint(equalToConstant: n).isActive = true }
}
func margins(_ y: CGFloat, _ x: CGFloat) -> NSEdgeInsets { NSEdgeInsets(top:y,left:x,bottom:y,right:x) }
func spring() -> NSView {
    let v = NSView()
    v.setContentHuggingPriority(.init(1), for: .horizontal)
    return v
}
func line(_ vertical: Bool = false) -> NSView {
    let v = surface(Ink.line)
    if vertical { v.width(1) } else { v.height(1) }
    return v
}
func symbol(_ name: String, _ size: CGFloat = 14) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(
        .init(pointSize: size, weight: .regular))
}
func glyph(_ name: String, _ color: NSColor = Ink.muted, _ size: CGFloat = 14) -> NSImageView {
    let v = NSImageView()
    v.image = symbol(name, size)
    v.contentTintColor = color
    return v
}
final class ActionButton: NSButton {
    var perform: (() -> Void)?
    init(_ title: String, _ icon: String? = nil, iconSize: CGFloat = 14, tip: String? = nil, run: @escaping () -> Void) {
        super.init(frame: .zero)
        self.title = title
        perform = run
        isBordered = false
        font = .systemFont(ofSize: 12)
        contentTintColor = Ink.muted
        if let icon {
            image = symbol(icon, iconSize)
            imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        }
        toolTip = tip ?? title
        setAccessibilityLabel(tip ?? title)
        target = self
        action = #selector(fire)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func fire() { perform?() }
}
func wrapped(_ inner: NSView, _ inset: NSEdgeInsets, _ color: NSColor = .clear) -> NSView {
    let v: NSView = color == .clear ? NSView() : surface(color)
    v.pin(inner, inset)
    return v
}
func fillRow(_ view: NSView, in parent: NSStackView) {
    parent.addArrangedSubview(view)
    view.widthAnchor.constraint(equalTo: parent.widthAnchor).isActive = true
}
func scroll(_ view: NSView? = nil) -> NSScrollView {
    let s = NSScrollView()
    s.drawsBackground = false
    s.hasVerticalScroller = true
    s.autohidesScrollers = true
    s.scrollerStyle = .overlay
    s.documentView = view
    return s
}
func fileIcon(_ url: URL) -> String {
    switch url.pathExtension.lowercased() {
    case "md","markdown": return "text.alignleft"
    case "json","yaml","yml","toml","plist": return "curlybraces"
    case "swift","js","ts","tsx","jsx","py","go","rs","sh","c","cpp","html","css": return "chevron.left.forwardslash.chevron.right"
    case "mp3": return "music.note"
    case "png","jpg","jpeg","webp","gif","svg": return "photo"
    default: return ImageDocument.supports(url) ? "photo" : "doc.text"
    }
}
