import Cocoa
import WebKit
import Sparkle

private func check(_ ok:@autoclosure ()->Bool,_ description:String) {
    if !ok() { FileHandle.standardError.write(Data(("FAIL "+description+"\n").utf8)); exit(1) }
    print("PASS "+description)
}
// Resolve the icon of this running app through Launch Services, as opposed to reading the source PNG.
private func checkSplitAppIcon() {
    guard let layer = Bundle.main.image(forResource:"FolioAppIcon_Assets/Folder") else {
        check(false,"modern icon artwork resolves from the installed catalog"); return
    }
    check(layer.size == NSSize(width:1024,height:1024),"modern icon artwork resolves at full size")
    if #unavailable(macOS 26) {
        guard let icon = NSRunningApplication.current.icon,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:256,pixelsHigh:256,bitsPerSample:8,
                samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0),
              let context = NSGraphicsContext(bitmapImageRep:bitmap) else {
            check(false,"running app supplies its classic icon"); return
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        icon.draw(in:NSRect(x:0,y:0,width:256,height:256),from:.zero,operation:.copy,fraction:1)
        NSGraphicsContext.restoreGraphicsState()
        let width = (0..<256).filter { (bitmap.colorAt(x:$0,y:128)?.alphaComponent ?? 0) >= 0.5 }.count
        check((205...207).contains(width),"classic icon has native-size margins on the running app")
    }
}
private func spin(_ seconds:Double = 5, until condition:()->Bool) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if condition() { return true }
        RunLoop.current.run(until:Date().addingTimeInterval(0.025))
    }
    return condition()
}
private func js(_ web:WKWebView,_ expression:String) -> Bool {
    var value:Bool?
    web.evaluateJavaScript(expression) { result,_ in value = result as? Bool ?? false }
    _ = spin(2) { value != nil }
    return value == true
}
func capture(_ w:NSWindow,_ path:URL) {
    w.contentView?.layoutSubtreeIfNeeded()
    w.displayIfNeeded()
    guard let view = w.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { return }
    view.cacheDisplay(in:view.bounds,to:bitmap)
    try? bitmap.representation(using:.png,properties:[:])?.write(to:path)
}
func runIntegration(_ e:Workspace) {
    setlinebuf(stdout)
    checkSplitAppIcon()
    let update = NSApp.mainMenu?.items.first?.submenu?.item(withTitle:L("Check for Updates…"))
    check(update?.target is SPUStandardUpdaterController && update?.action == #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
          "application menu checks for updates through Sparkle")

    if let dir = ProcessInfo.processInfo.environment["FOLIO_TEST_SOURCE_DIR"] {
        runSourceFileTests(e,at:URL(fileURLWithPath:dir,isDirectory:true)); return
    }
    if let path = ProcessInfo.processInfo.environment["FOLIO_TEST_REOPEN"] {
        let expected = [path,URL(fileURLWithPath:path).appendingPathComponent("Sources").path]
        check(e.items.filter { $0.1 == 0 }.map { $0.0.path } == expected,
              "relaunch restores project order and omits removed projects")
        check(e.folder?.path == path && e.items.contains { $0.1 == 1 },
              "restored project is ready to browse")
        check(e.docs.compactMap { $0.url?.lastPathComponent } == ["session-b.swift","session-a.swift","session-c.swift","Session.md"],
              "relaunch restores open tabs in order and skips missing or closed files")
        check(e.active?.title == "session-b.swift" && e.previewTab?.title == "session-c.swift",
              "relaunch restores selected and preview tabs independently")
        e.openFile(URL(fileURLWithPath:path).appendingPathComponent("README.md"),asPreview:true)
        check(!e.docs.contains { $0.title == "session-c.swift" } && e.docs.contains { $0.title == "session-b.swift" },
              "restored preview can be replaced while pinned tabs remain")
        if let profile = ProcessInfo.processInfo.environment["FOLIO_TEST_PROFILE"] {
            UserDefaults.standard.removePersistentDomain(forName:profile)
        }
        print("Verified project relaunch")
        exit(0)
    }
    DispatchQueue.global().asyncAfter(deadline:.now()+75) {
        FileHandle.standardError.write(Data("FAIL integration timeout\n".utf8)); exit(2)
    }
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("Folio-QA-"+UUID().uuidString,isDirectory:true).resolvingSymlinksInPath()
    func file(_ s:String) -> URL { tmp.appendingPathComponent(s) }
    func write(_ s:String,_ body:String) throws { try Data(body.utf8).write(to:file(s),options:.atomic) }
    do {
        for name in ["Sources","Design","Notes"] { try FileManager.default.createDirectory(at:file(name),withIntermediateDirectories:true) }
        try write(".gitignore","ignored.txt\n")
        try write("ignored.txt","needle")
        try write("Review.swift","let value = 1\n// needle\n")
        try write("Sources/utils.swift","struct Demo {\n    let number = 2\n}\n")
        try write("Design/icon.svg","<svg xmlns='http://www.w3.org/2000/svg' width='12' height='12'><rect width='12' height='12'/></svg>")
        let properties = """
        ---
        title: "The Batch Archive: 2025's Quiet Revolution"
        date: "2026-02-10"
        topic: Artificial Intelligence
        language: en
        summary: >-
          Weekly newsletter:
          <b>AI</b> & more
        tags: [AI, 技术]
        ---
        """
        check(FrontMatter("---\nOrdinary paragraph\n---\n") == nil && FrontMatter("---\ntitle: partial") == nil,
              "ordinary Markdown rules and unclosed delimiters stay in the body")
        check(FrontMatter(properties.replacingOccurrences(of:"\n",with:"\r\n")+"\r\nBody")?.body == "Body",
              "CRLF front matter ends before article body")
        try write("README.md",properties+"\n\n# 项目手册\n\n- [x] 打开项目\n\n| 模块 | 状态 |\n| --- | --- |\n| 编辑器 | 可用 |\n\n```swift\nlet value = 1\n```\n\n![图标](Design/icon.svg)\n")
        let welcomeAppearance = e.window.appearance
        e.window.appearance = NSAppearance(named:.darkAqua)
        capture(e.window,tmp.appendingPathComponent("welcome-dark.png"))
        e.window.appearance = welcomeAppearance
        e.open([tmp])
        check(e.root?.path == tmp.resolvingSymlinksInPath().path && e.items.contains { $0.0.lastPathComponent == "Design" },"open project and populate tree")
        for url in [tmp,file("Design"),file("README.md")] {
            let path = url.resolvingSymlinksInPath().path
            let index = e.items.firstIndex { $0.0.path == path }!
            let copy = e.tree.table.contextMenuForRow?(index)?.item(withTitle:L("Copy File Path"))
            check((copy?.representedObject as? URL)?.path == path && copy?.target === e &&
                  copy?.action == NSSelectorFromString("copyTreePath:"),
                  "copy path targets the clicked tree item: " + url.lastPathComponent)
        }
        check(e.body.bounds.height > 250 && e.tree.bounds.height > 100,"workspace layout")
        let projectWindowSize = e.window.contentView!.bounds.size
        e.showQuickOpen()
        check(spin { e.resultHits.contains { $0.url.lastPathComponent == "utils.swift" } },"quick-open without open documents")
        func verifySearchWidth() {
            e.window.contentView!.layoutSubtreeIfNeeded()
            let expected = e.window.contentView!.bounds.width - e.tree.bounds.width - 1 - 48
            let field = e.searchField!, list = e.resultList!
            check(abs(field.bounds.width-expected) < 2 && abs(list.table.tableColumns[0].width-expected) < 5,
                  "search field and result column fill available workspace width")
        }
        verifySearchWidth()
        e.window.setContentSize(NSSize(width:760,height:520))
        verifySearchWidth()
        e.window.setContentSize(projectWindowSize)
        verifySearchWidth()
        capture(e.window,tmp.appendingPathComponent("quick-open.png"))
        e.showBrowse(tmp)
        let originalFrame = e.window.frame
        func doubleClickHeader() {
            let event = NSEvent.mouseEvent(with:.leftMouseDown,location:NSPoint(x:e.window.frame.width-130,y:e.window.frame.height-36),modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:e.window.windowNumber,context:nil,eventNumber:1,clickCount:2,pressure:1)!
            e.window.sendEvent(event)
        }
        doubleClickHeader()
        check(e.window.frame.equalTo(e.window.screen!.visibleFrame),"double-click header maximizes to current screen")
        doubleClickHeader()
        check(e.window.frame.equalTo(originalFrame),"double-click restores original size and position")
        let systemAppearance = e.window.appearance
        for (theme,name) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            e.window.appearance = NSAppearance(named:theme)
            capture(e.window,tmp.appendingPathComponent("folders-"+name+".png"))
        }
        e.window.appearance = systemAppearance
        capture(e.window,tmp.appendingPathComponent("workspace.png"))
        e.newBuffer()
        let blank = e.active as! Buffer
        check(blank.url == nil && blank.source.string.isEmpty,"new untitled tab")
        blank.source.insertText("    func example()",replacementRange:NSRange(location:0,length:0))
        blank.source.insertNewline(nil)
        check(blank.source.string.hasSuffix("\n    ") && blank.dirty,"native text input, indentation and dirty state")
        check(AppLanguage.resolve(.system,preferred:["sv-SE","nl-NL"]) == .english &&
              AppLanguage.resolve(.system,preferred:["zh-CN"]) == .simplifiedChinese &&
              AppLanguage.resolve(.system,preferred:["sv-SE","zh-TW"]) == .traditionalChinese &&
              AppLanguage.resolve(.system,preferred:["fr-CA","ja-JP"]) == .french &&
              AppLanguage.resolve(.system,preferred:["pt-BR"]) == .portuguese,
              "system language matching and English fallback")
        let originalLanguage = Localization.choice
        let selection = blank.source.selectedRange()
        func pickLanguage(_ choice: AppLanguage) {
            let appMenu = NSApp.mainMenu!.items[0].submenu!
            let settings = appMenu.items[0]
            check(settings.title == L("Language Settings") && appMenu.items[1].action == #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                  "language settings immediately precede Check for Updates")
            let options = settings.submenu!
            let index = options.items.firstIndex { ($0.representedObject as? String) == choice.rawValue }!
            options.performActionForItem(at:index)
            let refreshed = NSApp.mainMenu!.items[0].submenu!.items[0].submenu!
            check(Localization.choice == choice && refreshed.items[index].state == .on,
                  "language menu saves and marks the selected preference")
        }
        for (choice,title,unsaved) in [(AppLanguage.english,"Untitled","Unsaved"),(.traditionalChinese,"未命名","尚未儲存"),(.simplifiedChinese,"未命名","未保存")] {
            pickLanguage(choice)
            check(e.active === blank && blank.dirty && blank.title == title && e.status.stringValue == unsaved &&
                  blank.source.selectedRange() == selection && blank.source.string.hasSuffix("\n    "),
                  "switching languages relabels the open document and preserves its edits and selection")
        }
        for (choice,caption) in [(AppLanguage.japanese,"プロジェクト"),(.korean,"프로젝트"),(.french,"Projets"),
                                 (.german,"Projekte"),(.spanish,"Proyectos"),(.portuguese,"Projetos"),
                                 (.italian,"Progetti"),(.russian,"Проекты")] {
            pickLanguage(choice)
            check(e.treeCaption.stringValue == caption && L("Unsaved") != "Unsaved","localized project heading and status in "+choice.rawValue)
        }
        e.showQuickOpen()
        e.searchField!.stringValue = "utils"
        pickLanguage(.english)
        check(e.page == .quick && e.searchField?.stringValue == "utils" && e.treeCaption.stringValue == "Projects",
              "language switch preserves the search query and refreshes sidebar labels")
        pickLanguage(.system)
        if originalLanguage != .system { pickLanguage(originalLanguage) }
        e.showEditor(blank)
        e.folder = file("Notes")
        let newURL = file("Notes/未命名.txt")
        try blank.save(to:newURL,expected:nil)
        check(e.saveActive(),"save active text document")
        check((try? String(contentsOf:newURL)) == blank.source.string,"first save writes untitled file")
        e.open([file("README.md")])
        let md = e.active as! Buffer, web = e.preview!.web
        check(md.mode == .preview && web.window === e.window && !md.hasEditor,"Markdown reading mode avoids allocating a source editor")
        let selector = e.editorActions.arrangedSubviews.compactMap { $0 as? NSSegmentedControl }.first!
        check(selector.bounds.height >= 24 && selector.width(forSegment:0) >= 44,"Markdown switch has padded segments")
        selector.selectedSegment = ReadMode.split.rawValue; e.switchMode(selector)
        check(md.scroller.bounds.width > 100 && web.bounds.width > 100,"visible split layout")
        let split = md.scroller.superview!.superview as! MarkdownSplitView
        func dragDivider(_ delta: CGFloat) {
            let x = split.arrangedSubviews[0].frame.maxX + split.dividerThickness / 2
            let start = split.convert(NSPoint(x:x,y:split.bounds.midY),to:nil)
            let end = NSPoint(x:start.x+delta,y:start.y)
            func event(_ type:NSEvent.EventType,_ point:NSPoint) -> NSEvent {
                NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,
                                   windowNumber:e.window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)!
            }
            NSApp.postEvent(event(.leftMouseUp,end),atStart:true)
            NSApp.postEvent(event(.leftMouseDragged,end),atStart:true)
            e.window.sendEvent(event(.leftMouseDown,start))
            e.window.contentView?.layoutSubtreeIfNeeded()
        }
        let initialWidth = md.scroller.bounds.width
        dragDivider(100)
        check(md.scroller.bounds.width > initialWidth+90 && web.bounds.width < initialWidth-90,"drag Markdown divider right")
        dragDivider(-160)
        let chosenWidth = md.scroller.bounds.width
        check(chosenWidth < initialWidth-50 && web.bounds.width > initialWidth+50,"drag Markdown divider left")
        e.showEditor(blank); e.showEditor(md)
        check(abs(md.scroller.bounds.width-chosenWidth) < 2,"returning to Markdown restores divider position")
        let previewOK = spin(8) { js(web,"!!document.querySelector('table td') && !!document.querySelector('input[type=checkbox]') && !!document.querySelector('pre code') && document.querySelector('img')?.naturalWidth===12") }
        if !previewOK {
            var logged = false
            web.evaluateJavaScript("JSON.stringify([document.baseURI,document.body.innerHTML,document.querySelector('img')?.complete,document.querySelector('img')?.naturalWidth])") { result, error in print("Preview DOM",result ?? "",error as Any); logged = true }; _ = spin { logged }
        }
        check(previewOK,"real WebKit renders GFM and local relative image")
        check(js(web,"""
        const meta = document.querySelector('main > header.frontmatter');
        !!meta && !meta.querySelector('dt') && Number(getComputedStyle(meta.querySelector('h1')).fontWeight) >= 700 &&
        meta.querySelector('h1').textContent === "The Batch Archive: 2025's Quiet Revolution" &&
        meta.querySelector('.byline').textContent === '2026-02-10 · Artificial Intelligence · en' &&
        meta.querySelector('.summary').textContent === 'Weekly newsletter: <b>AI</b> & more' &&
        meta.querySelectorAll('.tags span').length === 2 && !meta.querySelector('b') && meta.nextElementSibling.textContent === '项目手册';
        """),"article header displays bold title, concise byline, summary and tags without YAML labels")
        let initialFont = md.fontSize
        func fontShortcut(_ key:String,_ shift:Bool,_ keyCode:UInt16) -> Bool {
            let event = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:shift ? [.command,.shift] : .command,
                timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:e.window.windowNumber,context:nil,
                characters:key,charactersIgnoringModifiers:key,isARepeat:false,keyCode:keyCode)!
            return NSApp.mainMenu!.performKeyEquivalent(with:event)
        }
        check(!e.editorActions.arrangedSubviews.contains { $0.toolTip?.contains("文字") == true },"toolbar omits font-size buttons")
        check(fontShortcut("+",true,24),"Command-plus invokes text zoom")
        check(md.source.font?.pointSize == initialFont+1 && !md.dirty &&
              spin { js(web,"parseFloat(getComputedStyle(document.body).fontSize)>15") },"font control enlarges source and preview without modifying the file")
        e.showEditor(blank); check(blank.fontSize == initialFont,"font sizes are independent per tab")
        e.showEditor(md); check(md.fontSize == initialFont+1,"tab remembers font size")
        check(fontShortcut("-",false,27),"Command-minus invokes text zoom")
        check(spin { js(web,"parseFloat(getComputedStyle(document.body).fontSize)===15") },"minus restores preview font size")
        md.source.insertText("实时预览",replacementRange:NSRange(location:(md.source.string as NSString).length,length:0))
        check(spin { js(web,"document.querySelector('main').innerText.includes('实时预览')") },"live preview of unsaved edit")
        capture(e.window,tmp.appendingPathComponent("split.png"))
        e.togglePreview(); check(md.mode == .preview && web.window != nil,"preview only")
        check(spin { js(web,"window.innerWidth >= "+String(Int(e.body.bounds.width)-2)) },"reading mode expands the WebKit viewport across the editor")
        capture(e.window,tmp.appendingPathComponent("article-preview.png"))
        e.togglePreview(); check(md.mode == .source && md.source.window != nil,"source only")
        e.open([file("Review.swift")])
        let source = e.active as! Buffer
        for offset in [-11, 0, 9] {
            e.newBuffer()
            let disposable = e.active!
            e.showEditor(source)
            let close = e.tabViews[ObjectIdentifier(disposable)]!.nameButton.superview!.subviews.compactMap { $0 as? ActionButton }.first { $0.toolTip == L("Close %@",disposable.title) }!
            let rect = close.convert(close.bounds,to:nil)
            let point = NSPoint(x:rect.midX + (offset == 0 ? 0 : 12),y:rect.midY+CGFloat(offset))
            func clickEvent(_ type:NSEvent.EventType) -> NSEvent {
                NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,
                                   windowNumber:e.window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)!
            }
            NSApp.postEvent(clickEvent(.leftMouseUp),atStart:true)
            e.window.sendEvent(clickEvent(.leftMouseDown))
            check(!e.docs.contains { $0 === disposable } && e.active === source,"single click closes intended tab at vertical offset \(offset)")
        }
        let initialSelection = NSRange(location:4,length:5)
        source.source.setSelectedRange(initialSelection)
        e.showEditor(blank); check(!source.hasEditor,"pristine inactive source releases its TextKit stack"); e.showEditor(source)
        check(source.source.selectedRange() == initialSelection,"tab keeps selection")
        source.source.insertText("draft",replacementRange:initialSelection)
        source.source.breakUndoCoalescing()
        e.showEditor(blank); e.showEditor(source)
        source.source.history.undo()
        check(source.source.string.hasPrefix("let value") && !source.dirty,"independent undo after tab switch")
        source.refreshColors()
        let ink = source.source.layoutManager?.temporaryAttribute(.foregroundColor,atCharacterIndex:0,effectiveRange:nil) as? NSColor
        check(ink != nil && ink != Ink.text,"code keyword highlighting")
        let finder = NSMenuItem()
        finder.tag = NSTextFinder.Action.showReplaceInterface.rawValue
        source.source.performTextFinderAction(finder)
        check(spin { source.scroller.isFindBarVisible },"native find and replace bar")
        finder.tag = NSTextFinder.Action.hideFindInterface.rawValue
        source.source.performTextFinderAction(finder)
        try write("Review.swift","let value = 7\n// needle\n")
        check(spin { source.source.string.contains("= 7") },"clean tab follows atomic replace")
        let handle = try FileHandle(forWritingTo: file("Review.swift"))
        try handle.seekToEnd(); try handle.write(contentsOf:Data("// in-place\n".utf8)); try handle.close()
        check(spin { source.source.string.contains("in-place") },"watch reattached after atomic replace")
        source.source.insertText("// unsaved-needle",replacementRange:NSRange(location:(source.source.string as NSString).length,length:0))
        check(source.dirty,"edited native buffer")
        e.showProjectSearch(); e.searchField!.stringValue = "Needle"; e.runSearch()
        check(spin { e.resultHits.count == 2 } && e.resultHits.allSatisfy { $0.url.path == source.url?.path },
              "case-insensitive project search includes drafts and respects gitignore")
        e.openHit(e.resultHits.firstIndex { $0.excerpt.contains("unsaved-needle") }!)
        check(e.active === source && source.source.selectedRange().location == source.gutter.position(in:source.source.string as NSString,line:3).offset,"content match jumps to exact line")
        e.showQuickOpen(); e.searchField!.stringValue = "srcut"; e.runSearch()
        check(spin { e.resultHits.contains { $0.url.lastPathComponent == "utils.swift" } },"fuzzy quick-open on partial path")
        e.openHit(0); check(e.active?.url?.lastPathComponent == "utils.swift","quick-open selection")
        let unusual = file("matches:\nUnicode.txt")
        let longMatch = String(repeating:"树🌲 ",count:20000)
        try (longMatch+"\nnext 树🌲").write(to:unusual,atomically:true,encoding:.utf8)
        e.showProjectSearch(); e.searchField!.stringValue = "树🌲"; e.runSearch()
        check(spin { e.resultHits.count == 2 } && e.resultHits.allSatisfy { $0.url.path == unusual.path }
              && e.resultHits.map(\.line) == [1,2] && e.resultHits[0].excerpt == String(longMatch.prefix(250)),
              "bounded search previews keep Unicode, unusual filenames and one hit per matching line")
        e.showEditor(source)
        try write("Review.swift","// external change\n")
        check(spin { source.conflict && e.conflictBar?.isHidden == false } && source.source.string.contains("unsaved-needle"),"dirty tab retains edits and shows conflict banner")
        do { try source.save(to:file("Review.swift"),expected:source.baseline); check(false,"stale save rejected") }
        catch FileProblem.conflict { check((try? String(contentsOf:file("Review.swift"))) == "// external change\n","stale save preserves disk version") }
        let original = Data([0xef,0xbb,0xbf])+Data("a\r\nb".utf8)
        let disk = try TextFile(original)
        check(disk.text == "a\nb" && disk.encode(disk.text) == original,"BOM and CRLF preserved")
        let unicode = String(repeating:"🐾 中文 e\u{301}\r\n",count:12000)
        let utf16 = Data([0xff,0xfe]) + unicode.data(using:.utf16LittleEndian)!
        var compactFile = try TextFile(utf16)
        compactFile.compact()
        check(compactFile.encode(compactFile.text) == utf16,"compacted UTF-16 snapshot preserves Unicode, BOM and CRLF")
        compactFile.expand()
        check(compactFile.encode(compactFile.text) == utf16,"restored snapshot saves byte-for-byte")
        source.load(try TextFile.read(file("Review.swift")))
        e.closeBuffer(source)
        check(!e.docs.contains { $0 === source },"close individual file")
        e.window.setContentSize(NSSize(width:760,height:520))
        for _ in 0..<9 { e.newBuffer() }
        let longDoc = "A long filename to exercise scrolling in a narrow window.md"
        try write(longDoc,"# Narrow window")
        e.open([file(longDoc)])
        let doc = e.active as! Buffer, tab = e.tabViews[ObjectIdentifier(doc)]!.nameButton
        let strip = e.tabs
        let tabRect = tab.convert(tab.bounds,to:nil)
        let actions = e.editorActions.convert(e.editorActions.bounds,to:nil)
        let topOfEditor = web.convert(web.bounds,to:nil).maxY
        check(abs(tabRect.midY-actions.midY) < 2 && abs(e.window.frame.height-topOfEditor-50) < 2,
              "narrow editor uses one toolbar row")
        check(tabRect.width > 30 && strip.convert(strip.bounds,to:nil).contains(tabRect) && tabRect.maxX <= actions.minX,
              "selected tab scrolls into view beside Markdown controls")
        check(strip.row.arrangedSubviews.count == e.docs.count && strip.row.arrangedSubviews.allSatisfy { !$0.isHidden },
              "all open tabs remain in the horizontal row")
        let rightEdge = strip.contentView.bounds.minX
        check(rightEdge > 0 && !strip.hasHorizontalScroller,"offscreen tab is revealed without a bottom scrollbar")
        func scrollTabs(_ delta:Int32) {
            let cg = CGEvent(scrollWheelEvent2Source:nil,units:.pixel,wheelCount:2,wheel1:0,wheel2:delta,wheel3:0)!
            strip.scrollWheel(with:NSEvent(cgEvent:cg)!)
        }
        scrollTabs(120)
        check(spin { strip.contentView.bounds.minX < rightEdge },"horizontal wheel scrolls toward earlier tabs")
        let left = strip.contentView.bounds.minX
        scrollTabs(-120)
        check(spin { strip.contentView.bounds.minX > left } && !strip.hasHorizontalScroller,
              "horizontal wheel scrolls toward later tabs without showing a scrollbar")
        capture(e.window,tmp.appendingPathComponent("narrow-header.png"))
        // A complete sidebar shortcut should behave as one native button, even at its edges.
        func quickButton(in view:NSView) -> NSButton? {
            if view.identifier?.rawValue == "quickOpen" { return view as? NSButton }
            return view.subviews.lazy.compactMap { quickButton(in:$0) }.first
        }
        let quick = quickButton(in:e.rail)!
        let box = quick.superview!
        for x in [1.0, 16, 55, box.bounds.midX+14, box.bounds.maxX-16, box.bounds.maxX-1] {
            e.showBrowse(tmp)
            let point = box.convert(NSPoint(x:x,y:box.bounds.midY),to:nil)
            func mouse(_ type:NSEvent.EventType) -> NSEvent {
                NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,
                                   windowNumber:e.window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)!
            }
            NSApp.postEvent(mouse(.leftMouseUp),atStart:true)
            e.window.sendEvent(mouse(.leftMouseDown))
            check(e.page == .quick,"quick-open card responds at horizontal offset \(Int(x))")
        }
        check(abs(e.tree.convert(e.tree.bounds,to:nil).minY - e.rail.convert(e.rail.bounds,to:nil).minY) < 1,
              "sidebar tree extends to the bottom of the window")

        func bitmap(_ width:Int,_ type:NSBitmapImageRep.FileType = .png) -> Data {
            let rep = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:width,pixelsHigh:20,bitsPerSample:8,samplesPerPixel:3,
                hasAlpha:false,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
            let blue = NSColor(deviceRed:0.15,green:0.35,blue:0.75,alpha:1)
            for x in 0..<width { for y in 0..<20 { rep.setColor(blue,atX:x,y:y) } }
            return rep.representation(using:type,properties:[:])!
        }
        let imageURL = file("picture.png")
        for (name,data) in [("archive.zip",Data([0x50,0x4b,0,0])),("unknown.folio-fixture",Data([0,255,1])),
                            ("sample.pdf",Data("%PDF-1.4\n%%EOF".utf8))] {
            try data.write(to:file(name))
            e.showBrowse(tmp)
            check(spin { e.items.contains { $0.0.lastPathComponent == name } },"unsupported file appears in sidebar")
            e.selectTree(e.items.firstIndex { $0.0.lastPathComponent == name }!)
            let column = e.body.subviews.first?.subviews.first as? NSStackView
            let icon = column?.arrangedSubviews.first as? NSImageView
            let title = column?.arrangedSubviews.last as? NSTextField
            check(e.active is FileIconDocument && e.previewTab === e.active && icon?.image != nil &&
                  (icon?.bounds.width ?? 0) >= 128 && title?.stringValue == name && !e.saveActive(),
                  "sidebar opens read-only icon and filename for "+name)
        }
        let firstImage = bitmap(36)
        try firstImage.write(to:imageURL)
        e.showBrowse(tmp)
        check(spin { e.items.contains { $0.0.lastPathComponent == "picture.png" } },"image appears in file tree")
        e.selectTree(e.items.firstIndex { $0.0.lastPathComponent == "picture.png" }!)
        let picture = e.active as! ImageDocument
        check(picture.view.window === e.window && picture.view.image != nil && e.rightStatus.stringValue.contains("36 × 20"),"tree opens PNG preview with pixel dimensions")
        let savedImage = try Data(contentsOf:imageURL)
        check(!e.saveActive() && savedImage == firstImage,"image tab rejects text save")
        e.showEditor(md)
        check(picture.view.image == nil,"inactive image releases its bitmap")
        e.showQuickOpen(); e.searchField!.stringValue = "picture.png"; e.runSearch()
        check(spin { e.resultHits.first?.url.lastPathComponent == "picture.png" },"quick-open finds image files")
        e.openHit(0)
        check(e.active === picture && e.docs.filter { $0.url == picture.url }.count == 1,"quick-open reuses image tab")
        try bitmap(65).write(to:imageURL,options:.atomic)
        check(spin { picture.dimensions == "65 × 20" && picture.view.image != nil },"image follows atomic replacement")
        try FileManager.default.moveItem(at:imageURL,to:file("moved.png"))
        check(spin { picture.view.image == nil && e.status.stringValue == L("Image removed") },"missing image status")
        try firstImage.write(to:imageURL,options:.atomic)
        check(spin { picture.dimensions == "36 × 20" && picture.view.image != nil },"preview recovers after image returns")
        for (suffix,data) in [("jpg",bitmap(42,.jpeg)),("gif",bitmap(42,.gif)),("tiff",bitmap(42,.tiff))] {
            let path = file("test."+suffix)
            try data.write(to:path); e.open([path])
            check((e.active as? ImageDocument)?.dimensions == "42 × 20","open "+suffix+" through shared file opener")
        }
        e.open([file("Design/icon.svg")])
        check((e.active as? ImageDocument)?.view.image != nil,"open SVG directly")
        e.closeBuffer(picture)
        check(!e.docs.contains { $0 === picture },"close image tab")
        e.newBuffer()
        let pending = e.active as! Buffer
        pending.source.insertText("draft in original workspace",replacementRange:NSRange(location:0,length:0))
        let other = tmp.deletingLastPathComponent().appendingPathComponent("Folio-Second-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:other,withIntermediateDirectories:false)
        let child = file("Sources")
        let secondFile = other.appendingPathComponent("shared-name.txt")
        try "multi-root-needle".write(to:secondFile,atomically:true,encoding:.utf8)
        try write("Sources/shared-name.txt","multi-root-needle")
        let windowCount = NSApp.windows.filter { $0 is EditorWindow }.count
        e.open([child,other])
        let topLevel = e.items.filter { $0.1 == 0 }.map { $0.0.path }
        check(topLevel == [tmp.path,child.path,other.path] && NSApp.windows.filter { $0 is EditorWindow }.count == windowCount,
              "three project roots appear together in the original window")
        check(e.docs.contains { $0 === pending } && pending.dirty,"adding roots preserves unsaved tabs")
        e.selectTree(e.items.firstIndex { $0.0.path == other.path && $0.1 == 0 }!)
        guard let row = e.items.firstIndex(where:{ $0.0.path == secondFile.path }) else { check(false,"expand second project"); return }
        e.selectTree(row)
        check(e.active?.url?.path == secondFile.path && e.root?.path == other.path && e.expanded.contains { $0.path == tmp.path },"independent tree expansion and shared file tabs")
        e.open([other])
        check(e.roots.count == 3,"adding an existing project does not duplicate it")
        e.showQuickOpen(); e.searchField!.stringValue = "shared-name"; e.runSearch()
        check(spin { e.resultHits.count == 2 },"quick-open searches separate roots and deduplicates nested roots")
        e.showProjectSearch(); e.searchField!.stringValue = "multi-root-needle"; e.runSearch()
        check(spin { e.resultHits.count == 2 } && Set(e.resultHits.map { $0.url.path }).count == 2,"full-text search covers multiple roots without duplicate lines")
        e.openHit(e.resultHits.firstIndex { $0.url.path == file("Sources/shared-name.txt").path }!)
        check(e.root?.path == child.path,"cross-project result activates the owning root")
        let audioURL = other.appendingPathComponent("demo.mp3")
        try Data(contentsOf:Bundle.main.url(forResource:"test-silence",withExtension:"mp3")!).write(to:audioURL)
        e.open([audioURL])
        let audio = e.active as! AudioDocument
        check(audio.view.window === e.window && audio.timeline.maxValue >= 1.9 && audio.player?.isPlaying == false,"MP3 opens paused with duration")
        audio.playback.performClick(nil)
        check(spin { audio.player?.isPlaying == true && (audio.player?.currentTime ?? 0) > 0.05 },"MP3 plays through native decoder")
        audio.playback.performClick(nil)
        audio.timeline.doubleValue = 1; audio.seek()
        check(audio.player?.isPlaying == false && abs((audio.player?.currentTime ?? 0)-1)<0.1,"pause and seek MP3")
        audio.playback.performClick(nil)
        e.showEditor(pending)
        check(audio.player == nil,"hidden MP3 releases its player")
        e.showEditor(audio)
        check(audio.player?.isPlaying == false && (audio.player?.currentTime ?? 0) >= 0.95,"reopening MP3 restores the paused playhead")
        try write("index.html","<h1>Local page</h1>")
        e.open([file("index.html")])
        check(e.htmlURLForBrowser()?.path == file("index.html").path &&
              e.editorActions.arrangedSubviews.contains { ($0 as? NSButton)?.title == "" && $0.toolTip == L("Open in Browser") },"HTML toolbar uses the original local URL")
        let html = e.active as! Buffer
        html.source.insertText("!",replacementRange:NSRange(location:0,length:0))
        check(e.saveActive() && (try? String(contentsOf:file("index.html")))?.hasPrefix("!") == true,"HTML still saves normally")
        func themeButton(_ view:NSView) -> ThemeButton? {
            if let button = view as? ThemeButton { return button }
            return view.subviews.lazy.compactMap { themeButton($0) }.first
        }
        e.showEditor(md)
        md.source.insertText(String(repeating:"\n\nScroll test paragraph.",count:60),replacementRange:NSRange(location:(md.source.string as NSString).length,length:0))
        let theme = themeButton(e.rail)!
        for _ in 0..<2 {
            let targetDark = e.window.effectiveAppearance.bestMatch(from:[.darkAqua,.aqua]) != .darkAqua
            theme.performClick(nil)
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let overlay = e.window.contentView?.subviews.first { $0.identifier?.rawValue == "themeTransition" }
                check(overlay != nil && overlay?.hitTest(.zero) == nil,"theme transition starts without blocking clicks")
                check(spin(2) { overlay?.superview == nil },"theme transition finishes and removes snapshot")
            }
            check(spin { (e.window.effectiveAppearance.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua) == targetDark },"theme button changes native window")
            if md.mode == .source { e.togglePreview() }
            let web = e.preview!.web
            check(spin { js(web,"matchMedia('(prefers-color-scheme:dark)').matches === "+(targetDark ? "true" : "false")) },"Markdown preview uses selected appearance")
            check(spin { js(web,"window.scrollTo(0,document.documentElement.scrollHeight); scrollY > 0 && scrollY+innerHeight >= document.documentElement.scrollHeight-1") },
                  "Markdown preview reaches the bottom of a long document")
            check(spin {
                guard let color = web.underPageBackgroundColor.usingColorSpace(.sRGB) else { return false }
                let components = [color.redComponent,color.greenComponent,color.blueComponent].map { String(Int(($0*255).rounded())) }
                let css = "rgb("+components.joined(separator:", ")+")"
                return color.alphaComponent == 1 && js(web,"getComputedStyle(document.documentElement).backgroundColor === '"+css+"'")
            },"native scroll bounce uses the displayed Markdown background")
            NSApp.appearance = nil; ThemeButton.restorePreference()
            check((NSApp.appearance?.name == .darkAqua) == targetDark,"saved appearance restores")
        }
        e.showBrowse(other)
        capture(e.window,tmp.appendingPathComponent("multi-project-sidebar.png"))
        let host = e.window.contentView!
        let sidebarHandle = host.subviews.compactMap { $0 as? SidebarResizeHandle }.first!
        e.window.makeKeyAndOrderFront(nil)
        let readyToDrag = spin {
            host.layoutSubtreeIfNeeded()
            let point = sidebarHandle.convert(NSPoint(x:sidebarHandle.bounds.midX,y:sidebarHandle.bounds.midY),to:host)
            return e.window.isKeyWindow && host.hitTest(point) === sidebarHandle
        }
        check(readyToDrag,"main window receives sidebar drag after modal and popover interactions")
        let originalWidth = e.rail.bounds.width
        func moveSidebar(_ distance:CGFloat) {
            let start = sidebarHandle.convert(NSPoint(x:sidebarHandle.bounds.midX,y:sidebarHandle.bounds.midY),to:nil)
            let end = NSPoint(x:start.x+distance,y:start.y)
            for (type,location) in [(NSEvent.EventType.leftMouseDown,start),(.leftMouseDragged,end),(.leftMouseUp,end)] {
                e.window.sendEvent(NSEvent.mouseEvent(with:type,location:location,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,
                    windowNumber:e.window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)!)
            }
        }
        moveSidebar(50)
        check(spin(1) { abs(e.rail.bounds.width-originalWidth-50)<2 },
              "sidebar divider drags right (\(originalWidth) to \(e.rail.bounds.width), constraint \(sidebarHandle.widthConstraint.constant), window \(host.bounds.width))")
        moveSidebar(-70); check(abs(e.rail.bounds.width-originalWidth+20)<2,"sidebar divider drags left")
        let parentIndex = e.items.firstIndex { $0.0.path == other.path && $0.1 == 0 }!
        let rootMenu = e.treeMenu(for:parentIndex)!
        check(rootMenu.items.map(\.title).contains(L("Delete Project")),"root context menu offers project deletion")
        let deletion = rootMenu.item(withTitle:L("Delete Project"))!
        let cancel = Timer(timeInterval:0.12,repeats:true) { timer in
            guard NSApp.modalWindow != nil else { return }
            timer.invalidate(); NSApp.stopModal(withCode:.alertFirstButtonReturn)
        }
        RunLoop.main.add(cancel,forMode:.modalPanel)
        NSApp.sendAction(deletion.action!,to:deletion.target,from:deletion)
        check(e.roots.contains { $0.path == other.path } && FileManager.default.fileExists(atPath:secondFile.path),"cancelling delete leaves the project on disk and in the tree")
        let detach = rootMenu.item(withTitle:L("Remove Project"))!
        NSApp.sendAction(detach.action!,to:detach.target,from:detach)
        check(!e.roots.contains { $0.path == other.path } && FileManager.default.fileExists(atPath:secondFile.path) && pending.dirty,
              "removing a project only detaches it from sidebar")
        e.open([other]); e.showEditor(pending)
        let subdirectory = other.appendingPathComponent("QA-folder",isDirectory:true)
        try FileManager.default.createDirectory(at:subdirectory,withIntermediateDirectories:true)
        let nestedFile = subdirectory.appendingPathComponent("QA-file.txt")
        try "fixture".write(to:nestedFile,atomically:true,encoding:.utf8)
        for path in [nestedFile,subdirectory,other] {
            let destination = try e.trashTreeItem(path)
            check(!FileManager.default.fileExists(atPath:path.path) && destination != nil,"move test item to system Trash: "+path.lastPathComponent)
            // Return only our own uniquely created test fixture from the Trash.
            if let destination { try FileManager.default.moveItem(at:destination,to:path) }
        }
        check(!e.roots.contains { $0.path == other.path } && e.docs.contains { $0 === pending } && pending.dirty,
              "trashing a project unregisters its root and preserves drafts")
        let huge = file("oversized-preview.png")
        try bitmap(4096).write(to:huge)
        e.open([huge])
        let photo = e.active as! ImageDocument
        check(photo.dimensions == "4096 × 20" && (photo.view.image?.representations.first?.pixelsWide ?? 4096) < 3000,
              "large raster uses a display-sized decode and reports original pixels")

        let batch = (0..<3).map { file("batch-\($0).txt") }
        for (index,url) in batch.enumerated() { try ("File \(index)\n"+unicode).write(to:url,atomically:true,encoding:.utf8) }
        e.open([batch[0],batch[1],batch[0],batch[2]])
        let batchDocs = e.docs.compactMap { $0 as? Buffer }.filter { batch.contains($0.url ?? tmp) }
        check(batchDocs.count == 3 && batchDocs.filter(\.hasEditor).count == 1 && e.active?.url == batch.last,
              "batch open deduplicates tabs and only creates the visible source editor")
        let batchView = batchDocs.last!.source
        let reopened = batchDocs[0]
        e.showEditor(reopened)
        check(reopened.source === batchView && !reopened.source.history.canUndo && !batchDocs.last!.hasEditor,
              "switching pristine tabs reuses the editor without carrying undo history")
        check(reopened.source.string == "File 0\n"+unicode.replacingOccurrences(of:"\r\n",with:"\n"),
              "switching to a compacted background tab restores its entire text")
        let scrollFile = file("many-lines.swift")
        let largeText = "/*\n" + String(repeating:"an interior line of a block comment\n",count:4500) + "*/\nlet end = 1\n"
        try largeText.write(to:scrollFile,atomically:true,encoding:.utf8)
        e.open([scrollFile])
        let longBuffer = e.active as! Buffer
        longBuffer.go(3500)
        check(spin { longBuffer.scroller.contentView.bounds.minY > 500 },"long source scrolls to a distant line")
        func topLine() -> Int {
            let view = longBuffer.source
            let point = NSPoint(x:view.textContainer!.lineFragmentPadding,y:view.visibleRect.minY-view.textContainerOrigin.y)
            let glyph = view.layoutManager!.glyphIndex(for:point,in:view.textContainer!)
            return view.layoutManager!.characterIndexForGlyph(at:glyph)
        }
        let location = longBuffer.source.selectedRange().location
        longBuffer.refreshColors()
        let comment = longBuffer.source.layoutManager?.temporaryAttribute(.foregroundColor,atCharacterIndex:location,effectiveRange:nil) as? NSColor
        check(comment == Buffer.tokens.last!.1,"visible range inside an offscreen multiline comment is highlighted")
        let top = topLine()
        e.showEditor(pending); e.showEditor(longBuffer)
        check(longBuffer.source.selectedRange().location == location && topLine() == top,
              "recreated editor restores distant selection and scroll position")
        let previousDate = try FileManager.default.attributesOfItem(atPath:scrollFile.path)[.modificationDate]!
        try largeText.replacingOccurrences(of:"end = 1",with:"end = 2").write(to:scrollFile,atomically:false,encoding:.utf8)
        try FileManager.default.setAttributes([.modificationDate:previousDate],ofItemAtPath:scrollFile.path)
        longBuffer.reconcile()
        check(longBuffer.text.hasSuffix("end = 2\n"),"same-size external edit with restored mtime is detected")

        e.newBuffer()
        let lines = e.active as! Buffer
        func indexedLinesMatch() -> Bool {
            let string = lines.source.string as NSString
            var expected = [0], offset = 0
            while offset < string.length {
                var end = 0, contents = 0
                string.getLineStart(nil,end:&end,contentsEnd:&contents,for:NSRange(location:offset,length:0))
                if end < string.length || end > contents { expected.append(end) }
                offset = end
            }
            return expected.enumerated().allSatisfy { index,start in
                let found = lines.gutter.position(in:string,line:index)
                return found == (index,start) && lines.gutter.position(in:string,offset:start) == found
            } && lines.gutter.position(in:string,line:expected.count).offset == expected.last
        }
        for insertion in ["a\r\nb\n尾", "🐾\n", "三\u{2028}四", "\n\n", "\r", "\n"] {
            let pos = (lines.source.string as NSString).length
            lines.source.insertText(insertion,replacementRange:NSRange(location:pos,length:0))
            check(indexedLinesMatch(),"incremental UTF-16 line index matches the edited document")
        }
        lines.source.insertText("x",replacementRange:NSRange(location:1,length:4))
        check(indexedLinesMatch(),"line index survives replacement across line boundaries")
        lines.source.insertText(String(repeating:"🐾\r\n",count:550),replacementRange:NSRange(location:0,length:0))
        check(indexedLinesMatch(),"sparse line checkpoints span Unicode and CRLF")
        lines.source.insertText("尾",replacementRange:NSRange(location:1023,length:6))
        check(indexedLinesMatch(),"edits crossing a checkpoint rebuild subsequent offsets")
        e.showBrowse(tmp)
        check(spin(5) { e.preview == nil },"inactive Markdown renderer is released")
        let manyFolders = tmp.appendingPathComponent("many-folders",isDirectory:true)
        try FileManager.default.createDirectory(at:manyFolders,withIntermediateDirectories:true)
        for i in 0..<80 {
            try FileManager.default.createDirectory(at:manyFolders.appendingPathComponent(String(format:"folder-%03d",i)),withIntermediateDirectories:false)
        }
        e.showBrowse(manyFolders)
        func folderStrip(in view:NSView) -> FolderStrip? {
            if let strip = view as? FolderStrip { return strip }
            return view.subviews.lazy.compactMap { folderStrip(in:$0) }.first
        }
        let cards = folderStrip(in:e.body)!.documentView as! NSCollectionView
        let last = IndexPath(item:79,section:0)
        check(spin { !cards.visibleItems().isEmpty } && cards.numberOfItems(inSection:0) == 80 && cards.visibleItems().count < 12,
              "folder strip renders only nearby cards")
        cards.scrollToItems(at:[last],scrollPosition:.right)
        check(spin { cards.indexPathsForVisibleItems().contains(last) },"folder strip scrolls to offscreen directory")
        let lastTile = cards.item(at:last)!.view as! FolderTile
        check((lastTile.menu?.item(withTitle:L("New File"))?.representedObject as? URL)?.lastPathComponent == "folder-079",
              "reused overview card creates files in its current folder")
        check(lastTile.accessibilityPerformPress() && e.folder?.lastPathComponent == "folder-079","reused folder card opens the correct directory")
        // Close earlier temporary fixtures so the app can quit normally with a known session.
        for doc in e.docs {
            if let b = doc as? Buffer, b.dirty || b.conflict { b.load(b.file) }
            e.closeBuffer(doc)
        }
        for name in ["session-a.swift","session-b.swift","session-c.swift","session-gone.swift"] {
            try write(name,"let value = 1\n")
        }
        e.diskChanged()
        e.expanded.insert(tmp)
        e.showBrowse(tmp)
        func sessionRow(_ name:String) -> Int { e.items.firstIndex { $0.0.path == file(name).path }! }
        e.selectTree(sessionRow("session-a.swift"))
        e.selectTree(sessionRow("session-b.swift"))
        check(e.docs.count == 1 && e.previewTab?.title == "session-b.swift","single clicks replace the previous preview")
        let tree = e.tree.table
        // Let the filesystem notifications from writing the fixtures finish reloading the table.
        RunLoop.current.run(until:Date().addingTimeInterval(0.3))
        let index = sessionRow("session-b.swift")
        e.window.makeKeyAndOrderFront(nil)
        tree.scrollRowToVisible(index)
        e.window.contentView?.layoutSubtreeIfNeeded()
        if NSApp.isActive && e.window.isKeyWindow {
            for clicks in 1...2 {
                let rect = tree.rect(ofRow:index)
                let point = tree.convert(NSPoint(x:rect.midX,y:rect.midY),to:nil)
                let host = e.window.contentView!
                check(host.hitTest(host.convert(point,from:nil))?.isDescendant(of:tree) == true,
                      "test clicks a visible file row")
                func treeEvent(_ type:NSEvent.EventType) -> NSEvent {
                    NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,
                        windowNumber:e.window.windowNumber,context:nil,eventNumber:clicks,clickCount:clicks,pressure:1)!
                }
                NSApp.postEvent(treeEvent(.leftMouseUp),atStart:true)
                tree.mouseDown(with:treeEvent(.leftMouseDown))
            }
        } else {
            // macOS can give another app focus while this window is running the integration suite.
            // In that case validate the table's binding and exercise the same row action directly.
            check(tree.target === e.tree && tree.doubleAction != nil && e.tree.doubleSelect != nil,
                  "background window has the native table double-action binding")
            e.tree.doubleSelect?(index)
        }
        check(e.previewTab == nil,"double-clicking a tree file pins its tab (row \(index), clicked \(tree.clickedRow), selected \(tree.selectedRow), preview \(e.previewTab?.title ?? "none"))")
        e.selectTree(sessionRow("session-a.swift"))
        let edited = e.active as! Buffer
        edited.source.insertText("// note\n",replacementRange:NSRange(location:0,length:0))
        e.selectTree(sessionRow("session-c.swift"))
        check(e.docs.count == 3 && edited.dirty && e.previewTab?.title == "session-c.swift","editing a preview keeps its draft when another file opens")
        try edited.save(to:file("session-a.swift"),expected:edited.baseline)
        let notes = file("Notes")
        let create = e.treeMenu(for:sessionRow("Notes"))!.item(withTitle:L("New File"))!
        check(e.treeMenu(for:sessionRow("session-a.swift"))!.item(withTitle:L("New File")) == nil &&
              e.treeMenu(for:e.items.firstIndex { $0.0.path == tmp.path }!)!.item(withTitle:L("New File")) != nil,
              "only folders and project roots offer file creation")
        func submitName(_ text:String,for item:NSMenuItem) {
            let enterName = Timer(timeInterval:0.08,repeats:true) { timer in
                guard let window = NSApp.modalWindow else { return }
                func input(_ view:NSView) -> NSTextField? {
                    if let field = view as? NSTextField, field.isEditable { return field }
                    return view.subviews.lazy.compactMap(input).first
                }
                guard let field = window.contentView.flatMap(input) else { return }
                field.stringValue = text
                window.makeFirstResponder(nil)
                timer.invalidate()
                NSApp.stopModal(withCode:.alertFirstButtonReturn)
            }
            RunLoop.main.add(enterName,forMode:.modalPanel)
            NSApp.sendAction(item.action!,to:item.target,from:item)
        }
        submitName("Session.md",for:create)
        check(e.active?.url?.path == notes.appendingPathComponent("Session.md").path && (e.active as? Buffer)?.mode == .source &&
              e.items.contains { $0.0.path == e.active?.url?.path },"context action creates and opens the file in the clicked subfolder")
        do { try e.createItem(named:"session-a.swift",in:tmp,isFolder:false); check(false,"duplicate name rejected") }
        catch { check((try? String(contentsOf:file("session-a.swift")))?.hasPrefix("// note") == true,"file creation never overwrites a namesake") }
        let folderAction = e.treeMenu(for:sessionRow("Notes"))!.item(withTitle:L("New Folder"))!
        submitName("子目录",for:folderAction)
        let nested = notes.appendingPathComponent("子目录",isDirectory:true)
        check(isFolder(nested) && e.folder?.path == nested.path && e.items.contains { $0.0.path == nested.path },
              "folder action creates, reveals and opens a subdirectory of the clicked folder")
        for invalid in ["子目录","Session.md","../outside",""] {
            do { try e.createItem(named:invalid,in:notes,isFolder:true); check(false,"invalid or duplicate folder rejected") }
            catch { check(isFolder(nested),"invalid or duplicate folder leaves the existing directory intact") }
        }
        check((lastTile.menu?.item(withTitle:L("New Folder"))?.representedObject as? URL)?.lastPathComponent == "folder-079" &&
              e.treeMenu(for:sessionRow("session-a.swift"))!.item(withTitle:L("New Folder")) == nil &&
              e.treeMenu(for:e.items.firstIndex { $0.0.path == tmp.path }!)!.item(withTitle:L("New Folder")) != nil,
              "root and overview folders also offer subfolder creation")
        e.open([file("session-gone.swift")])
        e.showEditor(e.docs.first { $0.title == "session-b.swift" }!)
        print("Verified workspace at "+tmp.path)
        NSApp.terminate(nil)
    } catch { FileHandle.standardError.write(Data(("FAIL "+error.localizedDescription+"\n").utf8)); exit(1) }
}
