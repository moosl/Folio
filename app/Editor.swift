import AppKit
import CryptoKit

final class SourceView: NSTextView {
    let history = UndoManager()
    private(set) var usedFinder = false
    override func performTextFinderAction(_ sender:Any?) {
        usedFinder = true
        super.performTextFinderAction(sender)
    }

    override var undoManager: UndoManager? { history }
    override func insertNewline(_ sender: Any?) {
        let ns = string as NSString
        let line = ns.substring(with: ns.lineRange(for: NSRange(location: selectedRange().location, length: 0)))
        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
        super.insertNewline(sender)
        if !indent.isEmpty { insertText(indent, replacementRange: selectedRange()) }
    }
    override func insertTab(_ sender: Any?) { insertText("    ", replacementRange: selectedRange()) }
}
final class Gutter: NSRulerView {
    weak var source: SourceView?
    // UTF-16 offsets of every 256th line, filled only as far as the viewport or a jump needs.
    private let stride = 256
    private var checkpoints = [0]

    private func checkpoint(at offset:Int) -> Int {
        var lo = 0, hi = checkpoints.count
        while lo + 1 < hi {
            let mid = (lo + hi) / 2
            if checkpoints[mid] <= offset { lo = mid } else { hi = mid }
        }
        return lo
    }
    func invalidate(from offset:Int) {
        // The boundary at the edit itself can change when CR and LF join.
        let keep = checkpoint(at:max(0,offset-1)) + 1
        checkpoints.removeLast(checkpoints.count - keep)
        needsDisplay = true
    }
    private func nextStart(_ text:NSString,after at:Int) -> Int? {
        guard at < text.length else { return nil }
        var end = 0, contents = 0
        text.getLineStart(nil,end:&end,contentsEnd:&contents,for:NSRange(location:at,length:0))
        return end < text.length || contents < end ? end : nil
    }
    func position(in text:NSString,line:Int = .max,offset:Int = .max) -> (line:Int,offset:Int) {
        let block = min(max(0,line) / stride,checkpoint(at:offset))
        var number = block * stride, at = checkpoints[block]
        while number < line, at < offset, let next = nextStart(text,after:at), next <= offset {
            at = next
            number += 1
            if number % stride == 0 && number / stride == checkpoints.count { checkpoints.append(at) }
        }
        return (number,at)
    }
    override func drawHashMarksAndLabels(in rect: NSRect) {
        Ink.canvas.setFill()
        bounds.intersection(rect).fill()
        guard let tv = source, let lm = tv.layoutManager, let tc = tv.textContainer, let text = tv.textStorage?.mutableString else { return }
        let origin = tv.textContainerOrigin
        let offset = convert(.zero, from: tv).y
        let visible = tv.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = lm.glyphRange(forBoundingRect: visible, in: tc)
        let chars = lm.characterRange(forGlyphRange:glyphs, actualGlyphRange:nil)
        var (line,p) = position(in:text,offset:chars.location)
        let attrs: [NSAttributedString.Key:Any] = [.font:NSFont.monospacedDigitSystemFont(ofSize:max(9,(tv.font?.pointSize ?? 13)-2),weight:.regular),.foregroundColor:Ink.faint]
        while p <= NSMaxRange(chars) {
            let y = p == tv.textStorage?.length ? lm.extraLineFragmentRect.minY :
                lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at:p), effectiveRange:nil).minY
            let n = String(line+1) as NSString
            n.draw(at:NSPoint(x:ruleThickness-n.size(withAttributes:attrs).width-8,y:y+origin.y+offset+1),withAttributes:attrs)
            guard let next = nextStart(text,after:p) else { break }
            p = next; line += 1
        }
    }
}

private final class EditorViews {
    let source: SourceView
    let scroller = scroll()
    let gutter: Gutter
    // Explicit TextKit 1 stack; the editor uses NSLayoutManager for the ruler and syntax colours.
    let storage = NSTextStorage()
    init() {
        let layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = true
        layout.backgroundLayoutEnabled = false
        let container = NSTextContainer(size:NSSize(width:640,height:CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        source = SourceView(frame:NSRect(x:0,y:0,width:640,height:400),textContainer:container)
        gutter = Gutter(scrollView:scroller,orientation:.verticalRuler)
        gutter.clipsToBounds = true
    }
}

enum ReadMode: Int { case source, split, preview }
final class Buffer: NSObject, NSTextViewDelegate, NSTextStorageDelegate, WorkspaceDocument {
    var url: URL?
    private let untitledNumber: Int
    var untitled: String { untitledNumber <= 1 ? L("Untitled") : L("Untitled %ld",untitledNumber) }
    var title: String { url?.lastPathComponent ?? untitled }
    var markdown: Bool { ["md","markdown","mdown","mkd"].contains(url?.pathExtension.lowercased() ?? "") }
    private var editor: EditorViews?
    var hasEditor: Bool { editor != nil }
    private var selections = [NSValue(range:NSRange(location:0,length:0))]
    private var scrollPosition = NSPoint.zero
    private var needsScrollRestore = false
    private var topCharacter = 0
    private var topOffset: CGFloat = 0
    var source: SourceView { views().source }
    var scroller: NSScrollView { views().scroller }
    var gutter: Gutter { views().gutter }
    var text: String { dirty ? source.string : file.text }
    var file: TextFile
    var baseline: SHA256.Digest?
    private var lastChecked: FileRevision?
    private(set) var contentVersion: UInt64 = 0
    private var coloredRange: NSRange?
    private var commentSpans: [NSRange]?
    var dirty = false
    var conflict = false
    var missing = false
    static let defaultFontSize: CGFloat = 13
    private(set) var fontSize = Buffer.defaultFontSize
    var splitFraction: CGFloat = 0.5
    var mode: ReadMode = .source
    var changed: ((Bool) -> Void)?
    private var colorJob: DispatchWorkItem?
    static let tokens: [(NSRegularExpression,NSColor)] = [
        (#"\b(func|let|var|class|enum|struct|import|from|def|return|throw|throws|try|catch|function|const|export|async|await|if|else|switch|case|break|continue|for|in|while|guard|public|private|final|new|nil|null|true|false|fn|use|pub|type|interface|package|go|defer|match|impl|self)\b"#, dual(0xa4487a,0xe0a0bd)),
        (#"\b[0-9]+(?:\.[0-9]+)?\b"#,dual(0xb0621f,0xe8b57e)),
        (#"(?m)(?:\"(?:\\.|[^\"\\\n])*\"|'(?:\\.|[^'\\\n])*')"#,dual(0x5b7d43,0xadc792)),
        (#"(?m)^\s*#{1,6}\s.+$"#,dual(0xbf6a3f,0xe2a571)),
        (#"(?m)//[^\n]*|/\*[\s\S]*?\*/"#,dual(0xa3998c,0x847a70))
    ].map { (try! NSRegularExpression(pattern:$0.0),$0.1) }

    init(url: URL?, untitledNumber: Int = 1, file: TextFile) {
        self.url = url
        self.untitledNumber = untitledNumber
        self.file = file
        baseline = url == nil ? nil : file.digest
        lastChecked = file.revision
        super.init()
        if markdown { mode = .preview }
    }

    private func views() -> EditorViews {
        if let editor { return editor }
        let view = EditorViews()
        editor = view
        let source = view.source, scroller = view.scroller, gutter = view.gutter
        source.isRichText = false
        source.importsGraphics = false
        source.allowsUndo = true
        source.isAutomaticQuoteSubstitutionEnabled = false
        source.isAutomaticDashSubstitutionEnabled = false
        source.isAutomaticTextReplacementEnabled = false
        source.isAutomaticSpellingCorrectionEnabled = false
        source.isContinuousSpellCheckingEnabled = false
        source.usesFindBar = true
        source.isIncrementalSearchingEnabled = true
        source.isVerticallyResizable = true
        source.isHorizontallyResizable = false
        source.autoresizingMask = [.width]
        source.minSize = .zero
        source.maxSize = NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        source.textContainer?.widthTracksTextView = true
        source.textContainer?.containerSize = NSSize(width:0,height:CGFloat.greatestFiniteMagnitude)
        source.font = .monospacedSystemFont(ofSize:fontSize,weight:.regular)
        scroller.drawsBackground = true
        scroller.backgroundColor = Ink.canvas
        source.drawsBackground = false
        source.backgroundColor = Ink.canvas
        source.textColor = Ink.text
        source.textContainerInset = NSSize(width:12,height:18)
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 4
        source.defaultParagraphStyle = paragraph
        source.typingAttributes[.paragraphStyle] = paragraph
        source.selectedTextAttributes = [.backgroundColor:dual(0xbf6a3f,0xe2a571,0.24)]
        source.insertionPointColor = Ink.accent
        scroller.clipsToBounds = true
        scroller.documentView = source
        scroller.verticalRulerView = gutter
        scroller.hasVerticalRuler = true
        scroller.rulersVisible = true
        gutter.clientView = source
        gutter.source = source
        gutter.ruleThickness = 46
        bind(view)
        return view
    }
    private func bind(_ view:EditorViews) {
        let source = view.source, scroller = view.scroller
        view.gutter.invalidate(from:0)
        file.expand()
        source.string = file.text
        source.delegate = self
        view.storage.delegate = self
        let count = view.storage.length
        source.selectedRanges = selections.map {
            let at = min($0.rangeValue.location,count)
            return NSValue(range:NSRange(location:at,length:min($0.rangeValue.length,count-at)))
        }
        scroller.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self,selector:#selector(didScroll),name:NSView.boundsDidChangeNotification,object:scroller.contentView)
    }
    deinit {
        colorJob?.cancel()
        editor?.source.history.removeAllActions()
    }

    func textDidChange(_ notification: Notification) {
        guard let editor else { return }
        let wasDirty = dirty
        dirty = editor.storage.length != file.utf16Length || editor.source.string != file.text || (url != nil && baseline == nil)
        contentVersion &+= 1
        scheduleColors()
        changed?(wasDirty != dirty)
    }
    func textStorage(_ textStorage:NSTextStorage,didProcessEditing editedMask:NSTextStorageEditActions,
                     range editedRange:NSRange,changeInLength delta:Int) {
        guard editedMask.contains(.editedCharacters), let editor else { return }
        editor.gutter.invalidate(from:editedRange.location)
        if let previous = coloredRange {
            // LayoutManager adjusts existing temporary runs when the text changes.
            // Keep the invalidation covering those shifted runs until the next paint.
            let length = max(0, min(textStorage.length,NSMaxRange(previous)+max(0,delta))-min(previous.location,editedRange.location))
            coloredRange = NSRange(location:min(previous.location,editedRange.location),length:length)
        }
        commentSpans = nil
    }
    private func scheduleColors() {
        colorJob?.cancel()
        let job = DispatchWorkItem { [weak self] in self?.refreshColors() }
        colorJob = job
        DispatchQueue.main.asyncAfter(deadline:.now()+0.035,execute:job)
    }
    @objc private func didScroll() {
        guard let editor, editor.storage.length < 600_000, editor.storage.length > 24_000,
              let layout = editor.source.layoutManager, let container = editor.source.textContainer else { return }
        let glyphs = layout.glyphRange(forBoundingRect:editor.source.visibleRect,in:container)
        let visible = layout.characterRange(forGlyphRange:glyphs,actualGlyphRange:nil)
        if let coloredRange, NSIntersectionRange(coloredRange,visible) == visible { return }
        scheduleColors()
    }
    func refreshColors() {
        colorJob?.cancel(); colorJob = nil
        guard let editor, !editor.source.hasMarkedText(), let lm = editor.source.layoutManager,
              let tc = editor.source.textContainer else { return }
        let length = editor.storage.length
        if let old = coloredRange {
            let valid = NSIntersectionRange(old,NSRange(location:0,length:length))
            if valid.length > 0 { lm.removeTemporaryAttribute(.foregroundColor,forCharacterRange:valid) }
        }
        coloredRange = nil
        guard length > 0, length < 600_000 else { return }
        let ns = editor.storage.mutableString
        var range = NSRange(location:0,length:length)
        if length > 24_000 {
            let glyphs = lm.glyphRange(forBoundingRect:editor.source.visibleRect,in:tc)
            let visible = lm.characterRange(forGlyphRange:glyphs,actualGlyphRange:nil)
            let start = max(0,visible.location-2048)
            range = ns.lineRange(for:NSRange(location:start,length:min(length,NSMaxRange(visible)+2048)-start))
        }
        let fragment = ns.substring(with:range)
        let localRange = NSRange(location:0,length:range.length)
        for (regex,color) in Self.tokens {
            regex.enumerateMatches(in:fragment,range:localRange) { match,_,_ in
                if let r = match?.range {
                    lm.addTemporaryAttribute(.foregroundColor,value:color,
                        forCharacterRange:NSRange(location:range.location+r.location,length:r.length))
                }
            }
        }
        if range.length < length {
            if commentSpans == nil {
                var spans = [NSRange]()
                if ns.range(of:"/*",options:.literal).location != NSNotFound {
                    Self.tokens.last!.0.enumerateMatches(in:editor.source.string,range:NSRange(location:0,length:length)) { match,_,_ in
                        if let r = match?.range, ns.character(at:r.location+1) == 42 { spans.append(r) }
                    }
                }
                commentSpans = spans
            }
            for span in commentSpans ?? [] {
                let r = NSIntersectionRange(span,range)
                if r.length > 0 { lm.addTemporaryAttribute(.foregroundColor,value:Self.tokens.last!.1,forCharacterRange:r) }
            }
        }
        coloredRange = range
    }
    func releaseInactiveEditor() { _ = detachEditor(reusing:false) }

    func reuseSource(from previous:Buffer) -> Bool {
        guard editor == nil, fontSize == previous.fontSize, let old = previous.editor,
              !old.source.usedFinder, !old.scroller.isFindBarVisible,
              let view = previous.detachEditor(reusing:true) else { return false }
        editor = view
        needsScrollRestore = true
        bind(view)
        return true
    }
    private func detachEditor(reusing:Bool) -> EditorViews? {
        guard let view = editor else { file.compact(); return nil }
        guard !dirty, !view.source.hasMarkedText(),
              !view.source.history.canUndo, !view.source.history.canRedo else { return nil }
        selections = view.source.selectedRanges
        scrollPosition = view.scroller.contentView.bounds.origin
        topCharacter = 0; topOffset = 0
        if scrollPosition.y > 0, view.storage.length > 0, let lm = view.source.layoutManager, let tc = view.source.textContainer {
            let point = NSPoint(x:tc.lineFragmentPadding,y:max(0,scrollPosition.y-view.source.textContainerOrigin.y))
            let glyph = lm.glyphIndex(for:point,in:tc)
            if glyph < lm.numberOfGlyphs {
                topCharacter = lm.characterIndexForGlyph(at:glyph)
                topOffset = point.y-lm.lineFragmentRect(forGlyphAt:glyph,effectiveRange:nil).minY
            }
        }
        needsScrollRestore = true
        colorJob?.cancel(); colorJob = nil
        NotificationCenter.default.removeObserver(self,name:NSView.boundsDidChangeNotification,object:view.scroller.contentView)
        view.storage.delegate = nil
        view.source.delegate = nil
        if reusing, let range = coloredRange {
            let valid = NSIntersectionRange(range,NSRange(location:0,length:view.storage.length))
            if valid.length > 0 { view.source.layoutManager?.removeTemporaryAttribute(.foregroundColor,forCharacterRange:valid) }
        }
        editor = nil; coloredRange = nil; commentSpans = nil
        file.compact()
        return view
    }
    func didShowSource() {
        guard let editor else { return }
        if needsScrollRestore {
            var position = scrollPosition
            if scrollPosition.y > 0, editor.storage.length > 0, let lm = editor.source.layoutManager {
                let at = min(topCharacter,editor.storage.length-1)
                let range = NSRange(location:at,length:1)
                editor.source.scrollRangeToVisible(range)
                lm.ensureLayout(forCharacterRange:range)
                let glyph = lm.glyphIndexForCharacter(at:at)
                position.y = lm.lineFragmentRect(forGlyphAt:glyph,effectiveRange:nil).minY + editor.source.textContainerOrigin.y + topOffset
            }
            let clip = editor.scroller.contentView
            // The leading edge can have a negative scroll origin to accommodate the ruler.
            let viewport = clip.constrainBoundsRect(NSRect(origin:position,size:clip.bounds.size))
            clip.scroll(to:viewport.origin)
            editor.scroller.reflectScrolledClipView(clip)
            needsScrollRestore = false
        }
        if coloredRange == nil, editor.storage.length < 600_000 { refreshColors() }
    }
    func changeFontSize(by delta:CGFloat) {
        let size = min(36,max(9,fontSize+delta))
        guard size != fontSize else { return }
        fontSize = size
        guard editor != nil else { return }
        source.font = .monospacedSystemFont(ofSize:size,weight:.regular)
        gutter.ruleThickness = max(46,ceil(size * 3.4))
        gutter.needsDisplay = true
    }
    func go(_ line: Int) {
        let view = views()
        let at = view.gutter.position(in:view.storage.mutableString,line:max(1,line)-1).offset
        let r = NSRange(location:at,length:0)
        source.setSelectedRange(r)
        source.scrollRangeToVisible(r)
    }
    func load(_ disk: TextFile) {
        file = disk; baseline = disk.digest; lastChecked = disk.revision
        dirty = false; conflict = false; missing = false
        contentVersion &+= 1
        guard editor != nil else { changed?(true); return }
        let selection = source.selectedRange()
        let position = scroller.contentView.bounds.origin
        source.string = disk.text
        source.history.removeAllActions()
        let count = (source.string as NSString).length
        let loc = min(selection.location,count)
        source.setSelectedRange(NSRange(location:loc,length:min(selection.length,count-loc)))
        if let tc = source.textContainer { source.layoutManager?.ensureLayout(forBoundingRect:NSRect(origin:position,size:scroller.contentSize),in:tc) }
        scroller.contentView.scroll(to:position)
        refreshColors()
        changed?(true)
    }
    func reconcile() { reconcile(forceRead:false) }
    func reconcile(forceRead:Bool) {
        guard let url else { return }
        do {
            let revision = try FileRevision(url)
            guard forceRead || revision != lastChecked else { return }
            let disk = try TextFile.read(url,revision:revision)
            lastChecked = revision
            missing = false
            if disk.digest == baseline { conflict = false; return }
            if dirty || editor?.source.hasMarkedText() == true { conflict = true }
            else { load(disk) }
        } catch {
            lastChecked = nil
            missing = !FileManager.default.fileExists(atPath:url.path)
            conflict = true
        }
    }
    func save(to target: URL, expected: SHA256.Digest?) throws {
        let value = file.encode(editor?.source.string ?? file.text)
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt:target,options:.forReplacing,error:&coordinationError) { destination in
            do {
                let onDisk = try TextFile.diskDigest(destination)
                guard onDisk == expected else { throw FileProblem.conflict }
                try value.write(to:destination,options:.atomic)
            } catch { writeError = error }
        }
        if let error = writeError ?? coordinationError { throw error }
        url = target
        file = try TextFile(value)
        lastChecked = nil
        baseline = file.digest
        dirty = false
        conflict = false
        missing = false
        refreshColors()
    }
}
