import AppKit

final class MarkdownSplitView: NSSplitView, NSSplitViewDelegate {
    private weak var buffer: Buffer?
    private var trackingPosition = false
    private var usableWidth: CGFloat { max(0, bounds.width - dividerThickness) }
    private var minimumPaneWidth: CGFloat { min(120, usableWidth / 2) }

    init(buffer: Buffer, preview: NSView) {
        self.buffer = buffer
        super.init(frame: .zero)
        isVertical = true
        dividerStyle = .thin
        delegate = self
        for view in [buffer.scroller, preview] {
            let pane = NSView()
            pane.pin(view)
            addArrangedSubview(pane)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    // Keep the visible rule thin while giving the native drag target some width.
    override var dividerThickness: CGFloat { 9 }
    override func drawDivider(in rect: NSRect) {
        Ink.canvas.setFill()
        rect.fill()
        Ink.line.setFill()
        NSRect(x: rect.midX - 0.5, y: rect.minY, width: 1, height: rect.height).fill()
    }

    func restorePosition() {
        guard usableWidth > 0, let buffer else { return }
        let x = min(max(usableWidth * buffer.splitFraction, minimumPaneWidth), usableWidth - minimumPaneWidth)
        setPosition(x, ofDividerAt: 0)
        trackingPosition = true
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard trackingPosition, window != nil, usableWidth > 0, let first = arrangedSubviews.first else { return }
        buffer?.splitFraction = first.frame.width / usableWidth
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat { minimumPaneWidth }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat { usableWidth - minimumPaneWidth }
}
