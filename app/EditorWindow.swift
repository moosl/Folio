import AppKit

final class EditorWindow: NSWindow {
    private var frameBeforeMaximizing: NSRect?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, event.clickCount == 2,
           !styleMask.contains(.fullScreen), let screen,
           isTitleArea(event.locationInWindow) {
            let available = screen.visibleFrame
            if frame.equalTo(available), let previous = frameBeforeMaximizing {
                setFrame(previous,display:true)
                frameBeforeMaximizing = nil
            } else if !frame.equalTo(available) {
                frameBeforeMaximizing = frame
                setFrame(available,display:true)
            } else {
                zoom(nil)
            }
            return
        }
        super.sendEvent(event)
    }

    private func isTitleArea(_ point: NSPoint) -> Bool {
        guard let contentView, point.y >= contentView.bounds.maxY-49 else { return false }
        // Keep title-bar buttons and toolbar actions clickable, including their image views.
        for kind in [ButtonType.closeButton,.miniaturizeButton,.zoomButton] {
            if let button = standardWindowButton(kind),
               button.bounds.contains(button.convert(point,from:nil)) { return false }
        }
        var view = contentView.hitTest(contentView.convert(point,from:nil))
        while let hit = view {
            if hit is NSButton || hit is NSSegmentedControl { return false }
            view = hit.superview
        }
        return true
    }
}
