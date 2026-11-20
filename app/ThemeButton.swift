import AppKit

private final class ThemeSnapshot: NSImageView {
    override func hitTest(_ point:NSPoint) -> NSView? { nil }
}

final class ThemeButton: NSButton {
    private weak var transition: NSImageView?
    private static let key = "FolioAppearance"

    static func restorePreference() {
        let name = UserDefaults.standard.string(forKey:key).map { NSAppearance.Name($0) }
        NSApp.appearance = name.flatMap(NSAppearance.init(named:))
    }

    override init(frame:NSRect) {
        super.init(frame:frame)
        title = ""; imagePosition = .imageOnly; isBordered = false
        width(28); height(26)
        contentTintColor = Ink.muted
        target = self; action = #selector(toggle)
        updateIcon()
    }
    required init?(coder:NSCoder) { fatalError() }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateIcon()
    }
    private var dark: Bool { effectiveAppearance.bestMatch(from:[.aqua,.darkAqua]) == .darkAqua }
    private func updateIcon() {
        image = symbol(dark ? "sun.max" : "moon",12)
        let next = dark ? "切换到浅色模式" : "切换到深色模式"
        toolTip = next; setAccessibilityLabel(next)
    }
    @objc private func toggle() {
        let next: NSAppearance.Name = dark ? .aqua : .darkAqua
        var snapshot: NSImageView?
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
           let content = window?.contentView,
           let bitmap = content.bitmapImageRepForCachingDisplay(in:content.bounds) {
            content.cacheDisplay(in:content.bounds,to:bitmap)
            let image = NSImage(size:content.bounds.size)
            image.addRepresentation(bitmap)
            let overlay = ThemeSnapshot(frame:content.bounds)
            overlay.identifier = .init("themeTransition")
            overlay.image = image
            overlay.imageScaling = .scaleAxesIndependently
            overlay.autoresizingMask = [.width,.height]
            overlay.wantsLayer = true
            overlay.setAccessibilityElement(false)
            content.addSubview(overlay,positioned:.above,relativeTo:nil)
            snapshot = overlay
        }
        transition?.removeFromSuperview()
        transition = snapshot
        UserDefaults.standard.set(next.rawValue,forKey:Self.key)
        NSApp.appearance = NSAppearance(named:next)
        updateIcon()
        if let snapshot {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.35
                context.timingFunction = CAMediaTimingFunction(name:.easeInEaseOut)
                snapshot.animator().alphaValue = 0
            } completionHandler: {
                snapshot.removeFromSuperview()
            }
        }
    }
}
