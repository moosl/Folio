import AppKit

final class FolderArt: NSImageView {
    private static let light = Bundle.main.url(forResource:"FolderBox",withExtension:"svg").flatMap(NSImage.init(contentsOf:))

    private static let dark = Bundle.main.url(forResource:"FolderBoxDark",withExtension:"svg").flatMap(NSImage.init(contentsOf:))

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateArtwork()
    }
    private func updateArtwork() {
        image = effectiveAppearance.bestMatch(from:[.aqua,.darkAqua]) == .darkAqua ? Self.dark : Self.light
    }

    override init(frame:NSRect) {
        super.init(frame:frame)
        updateArtwork()
        imageScaling = .scaleProportionallyUpOrDown
    }
    required init?(coder:NSCoder) { fatalError() }
}

final class FolderTile: NSControl {
    private let name = label("",13,Ink.text,.medium)
    var activate: (() -> Void)?
    override init(frame:NSRect) {
        super.init(frame:frame)
        let art = FolderArt(frame:.zero)
        name.alignment = .center
        art.height(80)
        let column = stack(.vertical,[art,name],8)
        column.alignment = .centerX
        art.width(128); name.width(134)
        pin(column,NSEdgeInsets(top:14,left:8,bottom:12,right:8))
        setAccessibilityRole(.button)
    }
    func configure(_ url:URL,open:@escaping ()->Void) {
        name.stringValue = url.lastPathComponent
        setAccessibilityLabel(name.stringValue)
        toolTip = url.path
        activate = open
    }
    required init?(coder:NSCoder) { fatalError() }
    override func hitTest(_ point:NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func mouseDown(with event:NSEvent) { activate?() }
    override func accessibilityPerformPress() -> Bool { activate?(); return true }
}

private final class FolderItem: NSCollectionViewItem {
    override func loadView() { view = FolderTile(frame:NSRect(x:0,y:0,width:150,height:130)) }
}

final class FolderStrip: NSScrollView, NSCollectionViewDataSource {
    private let folders: [URL]
    private let open: (URL)->Void
    private let folderMenu: (URL)->NSMenu?
    init(_ folders:[URL],folderMenu:@escaping (URL)->NSMenu?,open:@escaping (URL)->Void) {
        self.folderMenu = folderMenu
        self.folders = folders; self.open = open
        super.init(frame:.zero)
        drawsBackground = false; hasHorizontalScroller = true
        autohidesScrollers = true; scrollerStyle = .overlay
        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = NSSize(width:150,height:130)
        layout.minimumLineSpacing = 14
        layout.sectionInset = NSEdgeInsets(top:4,left:2,bottom:16,right:16)
        let list = NSCollectionView()
        list.backgroundColors = [.clear]
        list.collectionViewLayout = layout
        list.register(FolderItem.self,forItemWithIdentifier:.init("folder"))
        list.dataSource = self
        documentView = list
        height(150)
    }
    required init?(coder:NSCoder) { fatalError() }
    func collectionView(_ collectionView:NSCollectionView,numberOfItemsInSection section:Int) -> Int { folders.count }
    func collectionView(_ collectionView:NSCollectionView,itemForRepresentedObjectAt path:IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier:.init("folder"),for:path)
        let url = folders[path.item]
        item.view.menu = folderMenu(url)
        (item.view as? FolderTile)?.configure(url) { [weak self] in self?.open(url) }
        return item
    }
}
final class DocumentTab: NSView {
    let nameButton: ActionButton
    let closeButton: ActionButton
    private let tile = surface(.clear,radius:8)
    private var selected = false
    private var previousPath = ""
    private var isPreview = false

    init(_ document:WorkspaceDocument,select:@escaping ()->Void,close:@escaping ()->Void) {
        nameButton = ActionButton(document.title,document.url.map(fileIcon) ?? "doc",run:select)
        closeButton = ActionButton("","xmark",run:close)
        super.init(frame:.zero)
        nameButton.cell?.lineBreakMode = .byTruncatingMiddle
        nameButton.widthAnchor.constraint(lessThanOrEqualToConstant:175).isActive = true
        closeButton.image = symbol("xmark",11)
        closeButton.contentTintColor = Ink.faint
        closeButton.width(28); closeButton.height(30)
        tile.pin(stack(.horizontal,[nameButton,closeButton],2),NSEdgeInsets(top:0,left:11,bottom:0,right:2))
        pin(tile); height(30)
    }
    required init?(coder:NSCoder) { fatalError() }
    func updateTitle(_ doc:WorkspaceDocument) {
        let value = doc.title + (doc.dirty ? " •" : "")
        if nameButton.title != value {
            nameButton.title = value
            superview?.needsLayout = true
        }
    }
    func update(_ doc:WorkspaceDocument,selected:Bool,preview:Bool) {
        if isPreview != preview {
            isPreview = preview
            let font = NSFont.systemFont(ofSize:12,weight:.medium)
            nameButton.font = preview ? NSFontManager.shared.convert(font,toHaveTrait:.italicFontMask) : font
        }
        updateTitle(doc)
        let path = doc.url?.path ?? doc.title
        if path != previousPath {
            nameButton.image = symbol(doc.url.map(fileIcon) ?? "doc")
            nameButton.toolTip = path; nameButton.setAccessibilityLabel(path)
            previousPath = path
        }
        let closeLabel = L("Close %@",doc.title)
        if closeButton.toolTip != closeLabel {
            closeButton.toolTip = closeLabel; closeButton.setAccessibilityLabel(closeLabel)
        }
        if selected != self.selected {
            self.selected = selected
            nameButton.contentTintColor = selected ? Ink.text : Ink.muted
            tile.fill = selected ? Ink.raised : .clear
            tile.border = selected ? Ink.line : nil
            tile.lift = selected
        }
    }
}

final class SidebarResizeHandle: NSView {
    let widthConstraint: NSLayoutConstraint
    private var startX: CGFloat = 0
    private var startWidth: CGFloat = 0

    init(widthConstraint:NSLayoutConstraint) {
        self.widthConstraint = widthConstraint
        super.init(frame:.zero)
        toolTip = L("Drag to resize the sidebar")
    }
    required init?(coder:NSCoder) { fatalError() }
    override var mouseDownCanMoveWindow: Bool { false }
    override func resetCursorRects() { addCursorRect(bounds,cursor:.resizeLeftRight) }
    override func mouseDown(with event:NSEvent) {
        startX = event.locationInWindow.x
        startWidth = (widthConstraint.firstItem as? NSView)?.bounds.width ?? widthConstraint.constant
    }
    override func mouseDragged(with event:NSEvent) {
        guard let content = window?.contentView else { return }
        widthConstraint.constant = min(max(160,startWidth + event.locationInWindow.x - startX),content.bounds.width-430)
        content.layoutSubtreeIfNeeded()
    }
}

final class RowTable: NSTableView {
    var contextMenuForRow: ((Int)->NSMenu?)?
    override func menu(for event:NSEvent) -> NSMenu? {
        guard let contextMenuForRow else { return super.menu(for:event) }
        return contextMenuForRow(row(at:convert(event.locationInWindow,from:nil)))
    }
}

final class RowList: NSView, NSTableViewDataSource, NSTableViewDelegate {
    let table = RowTable()
    var count = 0
    var row: ((Int)->NSView)?
    var select: ((Int)->Void)?
    var doubleSelect: ((Int)->Void)? {
        didSet { table.doubleAction = doubleSelect == nil ? nil : #selector(doubleClicked) }
    }
    static let sidebarFile = NSPasteboard.PasteboardType("local.folio.sidebar-file")
    var dragFile: ((Int)->URL?)?
    var dropFolder: ((Int,URL)->URL?)?
    var moveFile: ((URL,URL)->Bool)?
    var externalMove: ((URL,URL)->Void)?
    private var draggedFile: (url:URL, reference:NSURL?)?
    var deferSingleClick = false
    private var pendingClick: DispatchWorkItem?
    init(rowHeight:CGFloat) {
        super.init(frame:.zero)
        let col = NSTableColumn(identifier:.init("item")); col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.headerView = nil; table.backgroundColor = .clear
        table.selectionHighlightStyle = .none; table.intercellSpacing = NSSize(width:0,height:0)
        table.rowHeight = rowHeight
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.style = .plain
        table.dataSource = self; table.delegate = self
        table.target = self; table.action = #selector(clicked)
        pin(Folio.scroll(table))
    }
    required init?(coder:NSCoder) { fatalError() }
    func reset(_ total: Int) { count = total; table.reloadData() }
    func numberOfRows(in tableView:NSTableView) -> Int { count }
    func tableView(_ tableView:NSTableView,rowViewForRow row:Int) -> NSTableRowView? { SoftRow() }
    func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row index:Int) -> NSView? { row?(index) }
    func tableView(_ tableView:NSTableView,pasteboardWriterForRow row:Int) -> NSPasteboardWriting? {
        guard let url = dragFile?(row) else { return nil }
        let item = NSPasteboardItem()
        item.setString(url.absoluteString,forType:.fileURL)
        item.setString(url.absoluteString,forType:Self.sidebarFile)
        return item
    }
    func tableView(_ tableView:NSTableView,draggingSession session:NSDraggingSession,willBeginAt point:NSPoint,forRowIndexes rows:IndexSet) {
        guard let row = rows.first, let url = dragFile?(row) else { return }
        draggedFile = (url,(url as NSURL).fileReferenceURL() as NSURL?)
    }
    func tableView(_ tableView:NSTableView,validateDrop info:NSDraggingInfo,proposedRow row:Int,proposedDropOperation operation:NSTableView.DropOperation) -> NSDragOperation {
        guard info.draggingSource as? NSTableView === table, let source = draggedFile?.url,
              dropFolder?(row,source) != nil else { return [] }
        table.setDropRow(row,dropOperation:.on)
        return .move
    }
    func tableView(_ tableView:NSTableView,acceptDrop info:NSDraggingInfo,row:Int,dropOperation:NSTableView.DropOperation) -> Bool {
        guard info.draggingSource as? NSTableView === table, let source = draggedFile?.url,
              let folder = dropFolder?(row,source) else { return false }
        let moved = moveFile?(source,folder) == true
        if moved { draggedFile = nil }
        return moved
    }
    func tableView(_ tableView:NSTableView,draggingSession session:NSDraggingSession,endedAt point:NSPoint,operation:NSDragOperation) {
        defer { draggedFile = nil }
        guard operation.contains(.move), let file = draggedFile, let destination = file.reference?.filePathURL,
              destination.path != file.url.path else { return }
        externalMove?(file.url,destination)
    }
    @objc func clicked() {
        let i = table.clickedRow
        guard (0..<count).contains(i) else { return }
        guard deferSingleClick else { select?(i); return }
        // The overview is replaced when a file opens. Let its second click arrive first.
        pendingClick?.cancel()
        let job = DispatchWorkItem { [weak self] in
            guard let self, self.window != nil else { return }
            self.select?(i)
        }
        pendingClick = job
        DispatchQueue.main.asyncAfter(deadline:.now()+NSEvent.doubleClickInterval,execute:job)
    }
    @objc private func doubleClicked() {
        pendingClick?.cancel()
        let i = table.clickedRow
        if (0..<count).contains(i) { doubleSelect?(i) }
    }
}
/// Keyboard selection drawn as a soft accent wash instead of the system blue bar.
final class SoftRow: NSTableRowView {
    override func drawSelection(in dirtyRect:NSRect) {
        Ink.wash.setFill()
        NSBezierPath(roundedRect:bounds.insetBy(dx:2,dy:1),xRadius:7,yRadius:7).fill()
    }
    override var isEmphasized: Bool { get { false } set {} }
}
final class DropView: NSView {
    var open: (([URL])->Void)?
    override init(frame:NSRect) { super.init(frame:frame); registerForDraggedTypes([.fileURL]) }
    required init?(coder:NSCoder) { fatalError() }
    override func draggingEntered(_ sender:NSDraggingInfo) -> NSDragOperation { sender.draggingSource is RowTable ? [] : .copy }
    override func performDragOperation(_ sender:NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL] ?? []
        open?(urls); return !urls.isEmpty
    }
}
final class TabBar: NSScrollView {
    let row = stack(.horizontal,[],2)

    override init(frame:NSRect) {
        super.init(frame:frame)
        drawsBackground = false
        hasHorizontalScroller = false
        hasVerticalScroller = false
        automaticallyAdjustsContentInsets = false
        contentInsets = NSEdgeInsetsZero
        let host = NSView()
        documentView = host
        host.pin(row,NSEdgeInsets(top:0,left:2,bottom:0,right:2))
        host.translatesAutoresizingMaskIntoConstraints = false
        host.height(42)
        height(42)
    }
    required init?(coder:NSCoder) { fatalError() }
}
