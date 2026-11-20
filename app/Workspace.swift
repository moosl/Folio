import AppKit

enum Page { case browse, edit, quick, find }
final class Workspace: NSObject, NSWindowDelegate, NSSearchFieldDelegate {
    private(set) var roots = [URL]()
    private let projectDefaults: UserDefaults?
    #if FOLIO_STORE
    private let storeAccess = StoreFileAccess()
    #endif
    private let projectPathsKey = "FolioProjectPaths"
    private let tabsKey = "FolioOpenTabs"
    private(set) weak var previewTab: WorkspaceDocument?
    private var windowClosed = false
    let window: NSWindow
    let rail = stack(.vertical), main = stack(.vertical)
    let body = surface(Ink.canvas), tree = RowList(rowHeight:28)
    let crumb = stack(.horizontal,[],9), railTitle = label("Folio",17,Ink.text,.semibold)
    let tabs = TabBar(frame:.zero), treeCaption = label("项目文件",10,Ink.faint,.semibold)
    let editorActions = stack(.horizontal,[],10)
    let status = label("",11,Ink.muted), rightStatus = label("",11,Ink.faint)
    let search = SearchService(), watches = FileWatches()
    var root: URL?, folder: URL?, docs = [WorkspaceDocument](), active: WorkspaceDocument?
    var expanded = Set<URL>(), items = [(URL,Int)]()
    var page = Page.browse, counter = 0
    var preview: Preview?
    var conflictBar: NSView?
    private weak var sourceHost: NSView?
    private(set) var tabViews = [ObjectIdentifier:DocumentTab]()
    var searchField: NSSearchField?, resultList: RowList?, resultHits = [Hit]()
    private var releasePreview: DispatchWorkItem?
    private var lastContentQuery = ""
    var searchTitle: NSTextField?
    private var childCache = [URL:(children:[URL],revision:FileRevision?)]()
    private var treeRoots = [URL](), treeExpanded = Set<URL>()
    private var treeSelection: URL?
    private var treeDirty = true

    init(projectDefaults:UserDefaults? = .standard) {
        self.projectDefaults = projectDefaults
        window = EditorWindow(contentRect:NSRect(x:0,y:0,width:1120,height:735),styleMask:[.titled,.closable,.resizable,.miniaturizable,.fullSizeContentView],backing:.buffered,defer:false)
        super.init()
        window.minSize = NSSize(width:760,height:480)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.title = "Folio"; window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = Ink.canvas
        window.delegate = self
        window.center()
        makeShell()
        watches.onChange = { [weak self] in self?.diskChanged(paths:$0) }
        let savedRoots = projectDefaults?.stringArray(forKey:projectPathsKey) ?? []
        #if FOLIO_STORE
        var restoredPaths = savedRoots
        #endif
        for (index,path) in savedRoots.enumerated() where path.hasPrefix("/") {
            var url = URL(fileURLWithPath:path,isDirectory:true)
            #if FOLIO_STORE
            url = storeAccess.resolve(url)
            if url.path != path, isFolder(url) {
                restoredPaths[index] = url.path
                storeAccess.remember(url)
            }
            #endif
            if isFolder(url), !roots.contains(url) { roots.append(url) }
        }
        #if FOLIO_STORE
        if restoredPaths != savedRoots { projectDefaults?.set(restoredPaths,forKey:projectPathsKey) }
        #endif
        if let first = roots.first { expanded.insert(first) }
        showBrowse(roots.first)
        restoreTabs()
    }
    private func restoreTabs() {
        guard let state = projectDefaults?.dictionary(forKey:tabsKey),
              let paths = state["paths"] as? [String] else { return }
        var selected: WorkspaceDocument?
        for path in paths where path.hasPrefix("/") {
            autoreleasepool {
                var url = URL(fileURLWithPath:path,isDirectory:false)
                #if FOLIO_STORE
                url = storeAccess.resolve(url)
                #endif
                url = url.standardizedFileURL.resolvingSymlinksInPath()
                guard FileManager.default.fileExists(atPath:url.path), !isFolder(url),
                      let doc = document(at:url,reportErrors:false) else { return }
                (doc as? Buffer)?.file.compact()
                (doc as? AudioDocument)?.hide()
                if path == state["preview"] as? String { previewTab = doc }
                if path == state["selected"] as? String { selected = doc }
            }
        }
        if let doc = selected ?? docs.last { showEditor(doc) }
    }

    func makeShell() {
        let host = DropView(frame:.zero)
        host.open = { [weak self] urls in self?.open(urls) }
        window.contentView = host
        railTitle.font = serif(17)
        let sidebar = surface(Ink.rail); sidebar.pin(rail)
        let sidebarWidth = sidebar.widthAnchor.constraint(equalToConstant:232)
        sidebarWidth.priority = .init(999); sidebarWidth.isActive = true
        let mainPane = surface(Ink.canvas); mainPane.pin(main)
        let divider = line(true)
        let shell = stack(.horizontal,[sidebar,divider,mainPane])
        shell.alignment = .height
        host.pin(shell)
        sidebar.widthAnchor.constraint(lessThanOrEqualTo:host.widthAnchor,constant:-430).isActive = true
        mainPane.trailingAnchor.constraint(equalTo:shell.trailingAnchor).isActive = true
        let handle = SidebarResizeHandle(widthConstraint:sidebarWidth)
        host.addSubview(handle)
        handle.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([handle.centerXAnchor.constraint(equalTo:divider.centerXAnchor),
            handle.topAnchor.constraint(equalTo:host.topAnchor),handle.bottomAnchor.constraint(equalTo:host.bottomAnchor),
            handle.widthAnchor.constraint(equalToConstant:9)])
        let railHeader = stack(.horizontal,[railTitle,spring(),ThemeButton(frame:.zero)],8)
        // Sits below the traffic lights, left-aligned with the quick-open box.
        let brand = wrapped(railHeader,NSEdgeInsets(top:40,left:13,bottom:4,right:15))
        fillRow(brand,in:rail)
        let searchBox = surface(Ink.raised,radius:8); searchBox.border = Ink.line
        let quickTitle = label("快速打开…",12,Ink.muted)
        let key = label("⌘ P",10,Ink.faint,.medium)
        searchBox.pin(stack(.horizontal,[glyph("folder"),quickTitle,spring(),key],5),margins(3,10))
        let quick = ActionButton("",tip:"快速打开文件 (⌘P)") { [weak self] in self?.showQuickOpen() }
        quick.identifier = .init("quickOpen")
        searchBox.pin(quick)
        searchBox.height(32)
        fillRow(wrapped(searchBox,NSEdgeInsets(top:6,left:12,bottom:10,right:12)),in:rail)
        let find = ActionButton("  项目搜索","magnifyingglass",tip:"项目搜索 (⇧⌘F)") { [weak self] in self?.showProjectSearch() }
        find.alignment = .left
        let findRow = wrapped(find,margins(0,18)); findRow.height(32); fillRow(findRow,in:rail)
        let newFile = ActionButton("  新建文件","square.and.pencil") { [weak self] in self?.newBuffer() }
        newFile.alignment = .left
        let newFileRow = wrapped(newFile,margins(0,18)); newFileRow.height(32); fillRow(newFileRow,in:rail)
        let addProject = ActionButton("","folder",iconSize:12,tip:"添加项目文件夹") { [weak self] in self?.choose(true) }
        addProject.width(19); addProject.height(15)
        let section = stack(.horizontal,[treeCaption,spring(),addProject])
        fillRow(wrapped(section,NSEdgeInsets(top:20,left:16,bottom:8,right:16)),in:rail)
        fillRow(tree,in:rail)
        tree.table.contextMenuForRow = { [weak self] index in self?.treeMenu(for:index) }
        tree.row = { [weak self] i in self?.treeRow(i) ?? NSView() }
        tree.select = { [weak self] i in self?.selectTree(i) }
        tree.doubleSelect = { [weak self] i in
            guard let self, !self.items[i].0.hasDirectoryPath else { return }
            self.openFile(self.items[i].0)
        }
        tabs.setContentHuggingPriority(.init(1),for:.horizontal)
        tabs.setContentCompressionResistancePriority(.init(1),for:.horizontal)
        let top = stack(.horizontal,[crumb,tabs,editorActions,ActionButton("","doc.badge.plus",tip:"新建文件 (⌘N)") { [weak self] in self?.newBuffer() },ActionButton("","folder",tip:"打开文件 (⌘O)") { [weak self] in self?.choose(false) }],10)
        let topBox = wrapped(top,margins(0,14)); topBox.height(49); fillRow(topBox,in:main)
        fillRow(line(),in:main)
        fillRow(body,in:main)
        fillRow(line(),in:main)
        let foot = stack(.horizontal,[glyph("circle.fill",dual(0x86a77f,0x94b3a1),6),status,spring(),rightStatus],7)
        let footBox = wrapped(foot,margins(0,15)); footBox.height(29); fillRow(footBox,in:main)
    }
    func countBadge(_ n:Int) -> NSView {
        let pill = surface(Ink.card,radius:9)
        pill.pin(label(String(n),11,Ink.muted,.medium),margins(2,8))
        return pill
    }
    func clear(_ view:NSView) { view.subviews.forEach { $0.removeFromSuperview() } }
    func childrenFor(_ dir:URL) -> [URL] {
        if let existing = childCache[dir] { return existing.children }
        let revision = try? FileRevision(dir)
        let result = children(dir)
        childCache[dir] = (result,revision)
        return result
    }
    func treeRow(_ i:Int) -> NSView {
        let (u,depth) = items[i], dir = u.hasDirectoryPath
        let selected = (page == .edit && active?.url == u) || (page == .browse && folder == u)
        let disclosure = dir ? glyph(expanded.contains(u) ? "chevron.down" : "chevron.right",Ink.faint,8) : NSImageView()
        disclosure.width(9)
        let icon = glyph(dir ? "folder.fill" : fileIcon(u),dir ? Ink.accent : Ink.muted,12); icon.width(16)
        let name = label(u == root ? (root?.lastPathComponent ?? "") : u.lastPathComponent,12.5,selected ? Ink.accent : Ink.text,selected ? .medium : .regular)
        let row = stack(.horizontal,[disclosure,icon,name,spring()],6)
        let tile = surface(selected ? Ink.wash : .clear,radius:7)
        tile.pin(row,NSEdgeInsets(top:0,left:CGFloat(depth)*12+7,bottom:0,right:5))
        return wrapped(tile,margins(1,8))
    }
    func rebuildTree() {
        let selection = page == .edit ? active?.url : page == .browse ? folder : nil
        if !treeDirty, roots == treeRoots, expanded == treeExpanded {
            if selection != treeSelection {
                let visible = tree.table.rows(in:tree.table.visibleRect)
                if visible.location != NSNotFound {
                    let end = min(NSMaxRange(visible),items.count)
                    let rows = IndexSet((min(visible.location,end)..<end).filter {
                        items[$0].0 == selection || items[$0].0 == treeSelection
                    })
                    tree.table.reloadData(forRowIndexes:rows,columnIndexes:IndexSet(integer:0))
                }
            }
            treeSelection = selection
            return
        }
        treeDirty = false; treeRoots = roots; treeExpanded = expanded; treeSelection = selection
        items = []
        func add(_ u:URL,_ level:Int) {
            items.append((u,level))
            if expanded.contains(u), u.hasDirectoryPath, level < 32 {
                for child in childrenFor(u) where !roots.contains(child) { add(child,level+1) }
            }
        }
        for project in roots { add(project,0) }
        tree.reset(items.count)
    }
    func selectTree(_ i:Int) {
        let u = items[i].0
        if isFolder(u) {
            if expanded.contains(u) { expanded.remove(u) } else { expanded.insert(u) }
            showBrowse(u)
        } else { openFile(u,asPreview:true) }
    }
    func treeMenu(for index:Int) -> NSMenu? {
        guard items.indices.contains(index) else { return nil }
        let (url,level) = items[index]
        let menu = NSMenu()
        func item(_ title:String,_ action:Selector) {
            let entry = menu.addItem(withTitle:title,action:action,keyEquivalent:"")
            entry.target = self; entry.representedObject = url
        }
        if url.hasDirectoryPath { addCreationItems(to:menu,in:url) }
        item("复制文件路径",#selector(copyTreePath(_:)))
        menu.addItem(.separator())
        if level == 0 {
            item("移除项目",#selector(detachProject(_:)))
            menu.addItem(.separator())
        }
        item(level == 0 ? "删除项目…" : isFolder(url) ? "删除文件夹…" : "删除文件…",#selector(confirmTrash(_:)))
        return menu
    }
    private func addCreationItems(to menu:NSMenu,in dir:URL) {
        for (title,action) in [("新建文件…",#selector(newFileInFolder(_:))),("新建文件夹…",#selector(newFolderInFolder(_:)))] {
            let item = menu.addItem(withTitle:title,action:action,keyEquivalent:"")
            item.target = self; item.representedObject = dir
        }
    }
    @objc private func newFileInFolder(_ sender:NSMenuItem) { promptForNewItem(sender,isFolder:false) }
    @objc private func newFolderInFolder(_ sender:NSMenuItem) { promptForNewItem(sender,isFolder:true) }
    private func promptForNewItem(_ sender:NSMenuItem,isFolder:Bool) {
        guard let dir = sender.representedObject as? URL else { return }
        let kind = isFolder ? "文件夹" : "文件"
        let prompt = NSAlert()
        prompt.messageText = "在“\(dir.lastPathComponent)”中新建\(kind)"
        let name = NSTextField(frame:NSRect(x:0,y:0,width:280,height:24))
        name.placeholderString = isFolder ? "文件夹名称" : "文件名（含扩展名）"
        prompt.accessoryView = name
        prompt.addButton(withTitle:"创建"); prompt.addButton(withTitle:"取消")
        prompt.window.initialFirstResponder = name
        while prompt.runModal() == .alertFirstButtonReturn {
            do { try createItem(named:name.stringValue,in:dir,isFolder:isFolder); return }
            catch { prompt.informativeText = error.localizedDescription }
        }
    }
    func createItem(named name:String,in dir:URL,isFolder:Bool) throws {
        guard !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
              name != ".", name != "..", !name.contains("/"), !name.utf8.contains(0) else {
            throw NSError(domain:"Folio",code:1,userInfo:[NSLocalizedDescriptionKey:"请输入有效的名称。"])
        }
        let url = dir.appendingPathComponent(name,isDirectory:isFolder)
        if isFolder { try FileManager.default.createDirectory(at:url,withIntermediateDirectories:false) }
        else { try Data().write(to:url,options:.withoutOverwriting) }
        if let project = projectRoot(for:dir,in:roots) {
            var ancestor = dir.standardizedFileURL
            while ancestor.path != project.standardizedFileURL.path && ancestor.path != "/" {
                expanded.insert(ancestor)
                ancestor.deleteLastPathComponent()
            }
            expanded.insert(project)
        }
        childCache.removeValue(forKey:dir)
        treeDirty = true
        rebuildTree()
        if isFolder { showBrowse(url); return }
        if let doc = document(at:url) {
            if previewTab === doc { previewTab = nil }
            (doc as? Buffer)?.mode = .source
            showEditor(doc)
        }
    }
    @objc private func copyTreePath(_ sender:NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.path,forType:.string)
    }
    @objc private func detachProject(_ sender:NSMenuItem) {
        guard let url = sender.representedObject as? URL, roots.contains(url) else { return }
        removeProjectRoots { $0 == url }
        refreshAfterRemoval(url,trashed:false)
    }
    @objc private func confirmTrash(_ sender:NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        let prompt = NSAlert()
        prompt.alertStyle = .warning
        prompt.messageText = "将“\(url.lastPathComponent)”移到废纸篓？"
        prompt.informativeText = (isFolder(url) ? "此目录及其全部内容都会移到废纸篓。" : "这个文件会移到废纸篓。")+"\n"+url.path
        prompt.addButton(withTitle:"取消"); prompt.addButton(withTitle:"移到废纸篓")
        guard prompt.runModal() == .alertSecondButtonReturn else { return }
        do { try trashTreeItem(url) } catch { alert(error.localizedDescription) }
    }
    @discardableResult func trashTreeItem(_ url:URL) throws -> URL? {
        var destination: NSURL?
        try FileManager.default.trashItem(at:url,resultingItemURL:&destination)
        removeProjectRoots { inside($0,url) }
        refreshAfterRemoval(url,trashed:true)
        return destination as URL?
    }
    private func refreshAfterRemoval(_ url:URL,trashed:Bool) {
        childCache.removeAll(); treeDirty = true
        expanded = expanded.filter { projectRoot(for:$0,in:roots) != nil && !(trashed && inside($0,url)) }
        if let old = folder, let owner = projectRoot(for:old,in:roots), isFolder(old) {
            root = owner
        } else {
            root = roots.contains(where:{ $0 == root }) ? root : roots.first
            let parent = url.deletingLastPathComponent()
            folder = projectRoot(for:parent,in:roots) != nil && isFolder(parent) ? parent : root
        }
        if trashed { for doc in docs { doc.reconcile() } }
        switch page {
        case .edit:
            if let active { showEditor(active) } else { showBrowse(folder) }
        case .quick,.find:
            if roots.isEmpty { showBrowse(nil) }
            else { header(page == .quick ? "快速打开" : "项目搜索"); runSearch() }
        case .browse: showBrowse(folder)
        }
        updateWatches()
    }
    private func removeProjectRoots(where matches:(URL)->Bool) {
        roots.removeAll(where:matches)
        guard let saved = projectDefaults?.stringArray(forKey:projectPathsKey) else { return }
        let remaining = saved.filter { !matches(URL(fileURLWithPath:$0,isDirectory:true)) }
        if remaining != saved { projectDefaults?.set(remaining,forKey:projectPathsKey) }
    }
    func choose(_ directories:Bool) {
        let p = NSOpenPanel(); p.canChooseDirectories = directories
        p.canChooseFiles = !directories; p.allowsMultipleSelection = true
        p.directoryURL = folder ?? root
        p.prompt = directories ? "打开项目" : "打开"
        if p.runModal() == .OK { open(p.urls) }
    }
    func open(_ urls:[URL]) {
        var files = [URL](), projects = [URL]()
        for url in urls {
            #if FOLIO_STORE
            storeAccess.accept(url)
            storeAccess.remember(url)
            #endif
            let path = url.standardizedFileURL.resolvingSymlinksInPath()
            if isFolder(path) { projects.append(URL(fileURLWithPath:path.path,isDirectory:true)) }
            else { files.append(path) }
        }
        for project in projects where !roots.contains(project) {
            if roots.isEmpty { expanded.insert(project) }
            roots.append(project)
        }
        if let last = projects.last {
            if let projectDefaults {
                // Keep saved roots on temporarily disconnected volumes.
                var saved = projectDefaults.stringArray(forKey:projectPathsKey) ?? []
                let previousCount = saved.count
                for project in projects where !saved.contains(project.path) { saved.append(project.path) }
                if saved.count != previousCount { projectDefaults.set(saved,forKey:projectPathsKey) }
            }
            showBrowse(last)
            if let index = items.firstIndex(where:{ $0.0 == last && $0.1 == 0 }) { tree.table.scrollRowToVisible(index) }
        }
        var lastDocument: WorkspaceDocument?
        for url in files {
            autoreleasepool {
                guard let document = self.document(at:url,reportErrors:true) else { return }
                if previewTab === document { previewTab = nil }
                if lastDocument !== document {
                    if let previous = lastDocument as? Buffer, !previous.hasEditor { previous.file.compact() }
                    (lastDocument as? AudioDocument)?.hide()
                }
                lastDocument = document
            }
        }
        if let lastDocument { showEditor(lastDocument) }
    }
    func newBuffer() {
        counter += 1
        let b = Buffer(url:nil,name:counter == 1 ? "未命名" : "未命名 \(counter)",file:try! TextFile(Data()))
        attach(b); showEditor(b)
    }
    func openFile(_ url:URL,line:Int? = nil,asPreview:Bool = false) {
        let u = url.standardizedFileURL.resolvingSymlinksInPath()
        let existing = docs.first { $0.url == u }
        guard let doc = existing ?? document(at:u) else { return }
        if asPreview && previewTab !== doc {
            if let old = previewTab, !old.dirty,
               !((old as? Buffer).map { $0.conflict || ($0.hasEditor && $0.source.hasMarkedText()) } ?? false),
               let index = docs.firstIndex(where:{ $0 === old }) {
                removeTab(old)
                if existing == nil {
                    // The new document was appended by document(at:). Keep the preview slot in place.
                    docs.removeLast()
                    docs.insert(doc,at:index)
                }
            }
            previewTab = existing == nil ? doc : nil
        } else if !asPreview && previewTab === doc { previewTab = nil }
        showEditor(doc,line:line)
    }
    private func document(at u:URL,reportErrors:Bool = true) -> WorkspaceDocument? {
        if let existing = docs.first(where:{$0.url == u}) { return existing }
        do {
            let b: WorkspaceDocument
            if u.pathExtension.lowercased() == "mp3" {
                b = try AudioDocument(u)
            } else if ImageDocument.supports(u) {
                b = try ImageDocument(u)
            } else {
                b = Buffer(url:u,name:"",file:try TextFile.read(u))
            }
            attach(b); return b
        } catch { if reportErrors { alert(error.localizedDescription) }; return nil }
    }
    func attach(_ b:WorkspaceDocument) {
        docs.append(b)
        if let text = b as? Buffer {
            text.changed = { [weak self,weak text] statusChanged in
                guard let self, let text else { return }
                if text.dirty && self.previewTab === text {
                    self.previewTab = nil
                    self.rebuildTabs()
                }
                if statusChanged { self.updateStatus() }
                if self.active === text, self.page == .edit, text.mode != .source { self.preview?.show(text,root:self.root) }
            }
        }
    }
    func updateWatches() {
        var urls = docs.compactMap(\.url)
        urls += urls.map { $0.deletingLastPathComponent() }
        urls += roots
        urls += Array(expanded)
        if let folder { urls.append(folder) }
        watches.set(urls)
    }
    func diskChanged(paths:Set<String>? = nil) {
        func affected(_ url:URL) -> Bool {
            guard let paths else { return true }
            let value = url.path
            return paths.contains(value) || paths.contains { value.hasPrefix($0 == "/" ? "/" : $0 + "/") }
        }
        var browseChanged = false
        for directory in Array(childCache.keys) where affected(directory) {
            let revision = try? FileRevision(directory)
            if let revision, childCache[directory]?.revision == revision { continue }
            childCache.removeValue(forKey:directory)
            treeDirty = true
            if directory == folder { browseChanged = true }
        }
        for doc in docs {
            guard let url = doc.url, affected(url) else { continue }
            if let buffer = doc as? Buffer, paths?.contains(url.path) == true {
                // Direct inode notifications also cover writes on volumes with coarse timestamps.
                buffer.reconcile(forceRead:true)
            } else { doc.reconcile() }
        }
        if page == .browse && browseChanged {
            showBrowse(folder)
        } else {
            rebuildTree()
            if page == .quick || page == .find { runSearch() }
            updateWatches(); updateStatus()
        }
    }
    func header(_ leaf:String, path:URL? = nil) {
        clear(crumb)
        crumb.isHidden = page == .edit
        clear(editorActions)
        editorActions.isHidden = page != .edit
        if !crumb.isHidden {
            let home = ActionButton(root?.lastPathComponent ?? "Folio","square.stack.3d.up",tip:"返回项目") { [weak self] in self?.showBrowse(self?.root) }
            crumb.addArrangedSubview(home)
            if let path, let root, inside(path,root) {
                let middle = relative(path,to:root)
                if !middle.isEmpty {
                    crumb.addArrangedSubview(glyph("chevron.right",Ink.faint,9)); crumb.addArrangedSubview(label(middle,12,Ink.muted))
                }
            }
            crumb.addArrangedSubview(glyph("chevron.right",Ink.faint,9)); crumb.addArrangedSubview(label(leaf,12,Ink.text,.medium))
        }
        window.title = leaf+" — "+(root?.lastPathComponent ?? "Folio")
        if window.representedURL != root { window.representedURL = root }
        rebuildTabs()
        rebuildTree()
    }
    func rebuildTabs() {
        for (index,doc) in docs.enumerated() {
            let id = ObjectIdentifier(doc)
            let entry: DocumentTab
            if let existing = tabViews[id] { entry = existing }
            else {
                entry = DocumentTab(doc,select:{ [weak self, weak doc] in
                    guard let self, let doc else { return }
                    if let event = NSApp.currentEvent, [.leftMouseDown,.leftMouseUp].contains(event.type),
                       event.clickCount == 2, self.previewTab === doc { self.previewTab = nil }
                    self.showEditor(doc)
                },close:{ [weak self, weak doc] in
                    if let doc { self?.closeBuffer(doc) }
                })
                tabViews[id] = entry
                tabs.row.insertArrangedSubview(entry,at:index)
            }
            entry.update(doc,selected:page == .edit && active === doc,preview:previewTab === doc)
        }
    }
    func updateStatus() {
        for doc in docs { tabViews[ObjectIdentifier(doc)]?.updateTitle(doc) }
        window.isDocumentEdited = docs.contains { $0.dirty }
        if page == .edit, let audio = active as? AudioDocument {
            status.stringValue = audio.status; rightStatus.stringValue = "MP3"
        } else if page == .edit, let image = active as? ImageDocument {
            status.stringValue = image.status
            rightStatus.stringValue = [image.location.pathExtension.uppercased(), image.dimensions].filter { !$0.isEmpty }.joined(separator:"    ·    ")
        } else if page == .edit, let b = active as? Buffer {
            status.stringValue = b.conflict ? "磁盘文件已变化" : b.dirty ? "未保存" : b.url == nil ? "新建文件" : "已保存"
            let ext = b.url?.pathExtension.uppercased() ?? ""
            let codec = b.file.encoding == .utf8 ? "UTF-8" : "UTF-16"
            rightStatus.stringValue = [ext.isEmpty ? "纯文本" : ext,codec,b.file.newline == "\r\n" ? "CRLF" : b.file.newline == "\r" ? "CR" : "LF"].joined(separator:"    ·    ")
            conflictBar?.isHidden = !b.conflict
        }
    }
    private func deactivateDocument() {
        (active as? Buffer)?.releaseInactiveEditor()
        (active as? ImageDocument)?.hide()
        (active as? AudioDocument)?.hide()
    }

    private func retireUnusedPreview() {
        releasePreview?.cancel(); releasePreview = nil
        guard preview != nil else { return }
        if let b = active as? Buffer, page == .edit && b.markdown && b.mode != .source { return }
        guard docs.contains(where:{ ($0 as? Buffer)?.markdown == true }) else { preview = nil; return }
        // Allow immediate tab switches to reuse WebKit, then release its page and process pool.
        let job = DispatchWorkItem { [weak self] in self?.preview = nil; self?.releasePreview = nil }
        releasePreview = job
        DispatchQueue.main.asyncAfter(deadline:.now()+3,execute:job)
    }
    private func leaveSearch() {
        search.cancel()
        searchField = nil; searchTitle = nil; resultList = nil
        resultHits.removeAll()
    }
    func showBrowse(_ url:URL?) {
        deactivateDocument()
        page = .browse; retireUnusedPreview(); leaveSearch(); sourceHost = nil
        folder = url ?? root; conflictBar = nil
        if let folder { root = projectRoot(for:folder,in:roots) }
        header(folder == root ? "项目概览" : folder?.lastPathComponent ?? "工作区",path:folder != root ? folder?.deletingLastPathComponent() : nil)
        clear(body)
        guard let dir = folder else { welcome(); updateStatus(); return }
        let all = childrenFor(dir), dirs = all.filter(\.hasDirectoryPath), files = all.filter { !$0.hasDirectoryPath }
        let col = stack(.vertical)
        body.pin(col,NSEdgeInsets(top:28,left:32,bottom:12,right:32))
        if !dirs.isEmpty {
            let heading = stack(.horizontal,[label("文件夹",17,Ink.text,.semibold),countBadge(dirs.count),spring()],9)
            fillRow(heading,in:col)
            let strip = FolderStrip(dirs,folderMenu:{ [weak self] dir in
                guard let self else { return nil }
                let menu = NSMenu()
                self.addCreationItems(to:menu,in:dir)
                return menu
            }) { [weak self] url in
                self?.expanded.insert(url); self?.showBrowse(url)
            }
            fillRow(wrapped(strip,NSEdgeInsets(top:10,left:-2,bottom:12,right:0)),in:col)
        }
        fillRow(stack(.horizontal,[label("文件",17,Ink.text,.semibold),countBadge(files.count),spring()],9),in:col)
        let headerRow = stack(.horizontal,[label("名称",11,Ink.muted),spring(),label("类型",11,Ink.muted)],6)
        let headerTile = surface(Ink.card,radius:8); headerTile.pin(headerRow,margins(8,14))
        fillRow(wrapped(headerTile,NSEdgeInsets(top:12,left:0,bottom:2,right:0)),in:col)
        let list = RowList(rowHeight:40)
        list.row = { i in
            let u = files[i]
            let row = stack(.horizontal,[glyph(fileIcon(u),Ink.accent,13),label(u.lastPathComponent,13),spring(),label(u.pathExtension.isEmpty ? "文本" : u.pathExtension.uppercased(),10,Ink.faint,.medium)],11)
            let v = stack(.vertical)
            fillRow(wrapped(row,margins(10,14)),in:v); fillRow(wrapped(line(),margins(0,14)),in:v)
            return v
        }
        list.deferSingleClick = true
        list.select = { [weak self] i in self?.openFile(files[i],asPreview:true) }
        list.doubleSelect = { [weak self] i in self?.openFile(files[i]) }
        list.reset(files.count)
        if files.isEmpty { fillRow(wrapped(label("此目录下没有文件",12,Ink.faint),margins(14,14)),in:col) }
        fillRow(list,in:col)
        status.stringValue = dir.lastPathComponent
        rightStatus.stringValue = "\(dirs.count) 个文件夹    ·    \(files.count) 个文件"
        updateWatches(); updateStatus()
    }
    func welcome() {
        let box = stack(.vertical,[],10)
        let art = FolderArt(frame:.zero); art.width(140); art.height(96)
        box.addArrangedSubview(art); box.setCustomSpacing(18,after:art)
        let hint = label("打开一个项目文件夹，或从一张空白页开始",13,Ink.muted)
        box.addArrangedSubview(hint); box.setCustomSpacing(24,after:hint)
        let actions = stack(.horizontal,[],10)
        let welcomeActions: [(String,String,()->Void)] = [("打开项目","folder",{ [weak self] in self?.choose(true) }),("打开文件","doc",{ [weak self] in self?.choose(false) }),("新建文件","square.and.pencil",{ [weak self] in self?.newBuffer() })]
        for (i,(text,icon,run)) in welcomeActions.enumerated() {
            let btn = ActionButton(" "+text,icon,run:run)
            btn.font = .systemFont(ofSize:13,weight:.medium)
            let tile = surface(i == 0 ? Ink.accent : Ink.raised,radius:9)
            if i == 0 { btn.contentTintColor = dual(0xffffff,0x1f1b18); tile.lift = true } else { btn.contentTintColor = Ink.text; tile.border = Ink.line }
            tile.pin(btn,margins(9,16)); actions.addArrangedSubview(tile)
        }
        box.addArrangedSubview(actions); box.alignment = .centerX
        body.addSubview(box); box.translatesAutoresizingMaskIntoConstraints = false
        box.centerXAnchor.constraint(equalTo:body.centerXAnchor).isActive = true
        box.centerYAnchor.constraint(equalTo:body.centerYAnchor).isActive = true
        status.stringValue = "就绪"; rightStatus.stringValue = ""
    }
    func showEditor(_ document:WorkspaceDocument,line jump:Int? = nil) {
        leaveSearch()
        let existingHost = page == .edit ? sourceHost : nil
        if active !== document {
            let reused: Bool
            if existingHost != nil, let previous = active as? Buffer, let incoming = document as? Buffer, !incoming.markdown {
                reused = incoming.reuseSource(from:previous)
            } else { reused = false }
            if !reused { deactivateDocument() }
        }
        if let url = document.url, let project = projectRoot(for:url,in:roots), project != root {
            root = project; folder = project
        }
        active = document; page = .edit; retireUnusedPreview()
        header(document.title,path:document.url?.deletingLastPathComponent())
        if let host = existingHost, let buffer = document as? Buffer, !buffer.markdown {
            if buffer.scroller.superview !== host {
                clear(host)
                host.pin(buffer.scroller)
            }
            addBrowserAction(buffer)
            window.contentView?.layoutSubtreeIfNeeded()
            window.makeFirstResponder(buffer.source)
            buffer.didShowSource()
            if let jump { buffer.go(jump) }
        } else {
            sourceHost = nil
            clear(body)
            mountDocument(document,line:jump)
        }
        window.contentView?.layoutSubtreeIfNeeded()
        if let tab = tabViews[ObjectIdentifier(document)] { tab.scrollToVisible(tab.bounds) }
        updateStatus(); updateWatches()
        #if FOLIO_STORE
        storeAccess.releaseUnused(keeping:roots + docs.compactMap(\.url))
        #endif
    }
    private func mountDocument(_ document:WorkspaceDocument,line jump:Int?) {
        if let audio = document as? AudioDocument {
            audio.show()
            conflictBar = nil; body.pin(audio.view,margins(24,24)); window.makeFirstResponder(nil)
        } else if let image = document as? ImageDocument {
            conflictBar = nil
            body.pin(image.view,margins(16,16))
            body.layoutSubtreeIfNeeded()
            image.show()
            window.makeFirstResponder(nil)
        } else if let buffer = document as? Buffer {
            showText(buffer,line:jump)
        }
    }
    private func addBrowserAction(_ b:Buffer) {
        if let url = b.url, ["html","htm"].contains(url.pathExtension.lowercased()) {
            editorActions.addArrangedSubview(ActionButton("","safari",iconSize:17,tip:"在浏览器打开") { [weak self] in self?.openHTML() })
        }
    }
    private func showText(_ b:Buffer,line jump:Int?) {
        if jump != nil && b.mode == .preview { b.mode = .split }
        let column = stack(.vertical)
        body.pin(column)
        if b.markdown {
            let modes = NSSegmentedControl(labels:["源码","分栏","预览"],trackingMode:.selectOne,target:self,action:#selector(switchMode(_:)))
            modes.segmentStyle = .rounded; modes.controlSize = .regular
            modes.font = .systemFont(ofSize:12,weight:.medium)
            modes.height(26)
            for i in 0..<modes.segmentCount { modes.setWidth(46,forSegment:i) }
            modes.selectedSegment = b.mode.rawValue
            editorActions.addArrangedSubview(modes)
        }
        addBrowserAction(b)
        let conflict = stack(.horizontal,[glyph("exclamationmark.triangle",Ink.warn),label("文件已在外部更改",12),spring(),ActionButton("查看并处理") { [weak self] in if let b = self?.active as? Buffer { self?.resolve(b) } }],8)
        let banner = wrapped(conflict,margins(8,16),Ink.warnWash)
        fillRow(banner,in:column); conflictBar = banner; banner.isHidden = !b.conflict
        let content = NSView(); fillRow(content,in:column)
        if !b.markdown { sourceHost = content }
        if !b.markdown || b.mode == .source { content.pin(b.scroller) }
        else {
            let pv = preview ?? Preview(); preview = pv
            if b.mode == .preview { content.pin(pv.web) }
            else {
                let split = MarkdownSplitView(buffer:b,preview:pv.web)
                content.pin(split)
                window.contentView?.layoutSubtreeIfNeeded()
                split.restorePosition()
            }
            pv.show(b,root:root)
        }
        window.contentView?.layoutSubtreeIfNeeded()
        if b.mode != .preview {
            window.makeFirstResponder(b.source)
            b.didShowSource()
        } else { b.releaseInactiveEditor() }
        if let jump { b.go(jump) }
    }
    func changeFontSize(by delta:CGFloat) {
        guard page == .edit, let buffer = active as? Buffer else { return }
        buffer.changeFontSize(by:delta)
        if buffer.markdown && buffer.mode != .source { preview?.setFontSize(buffer.fontSize) }
    }
    func htmlURLForBrowser() -> URL? {
        guard let buffer = active as? Buffer, let url = buffer.url,
              ["html","htm"].contains(url.pathExtension.lowercased()) else { return nil }
        if buffer.dirty {
            let prompt = NSAlert()
            prompt.messageText = "保存修改后在浏览器中打开？"
            prompt.addButton(withTitle:"保存并打开"); prompt.addButton(withTitle:"取消"); prompt.addButton(withTitle:"打开磁盘版本")
            switch prompt.runModal() {
            case .alertFirstButtonReturn: guard saveActive() else { return nil }
            case .alertThirdButtonReturn: break
            default: return nil
            }
        }
        return url
    }
    func openHTML() {
        guard let url = htmlURLForBrowser() else { return }
        let system = NSWorkspace.shared
        guard let browser = system.urlForApplication(toOpen:URL(string:"https://example.com")!) else {
            alert("找不到默认浏览器。"); return
        }
        system.open([url],withApplicationAt:browser,configuration:.init()) { [weak self] _,error in
            if let error { DispatchQueue.main.async { self?.alert(error.localizedDescription) } }
        }
    }
    @objc func switchMode(_ sender:NSSegmentedControl) {
        guard let b = active as? Buffer,let mode = ReadMode(rawValue:sender.selectedSegment) else { return }
        b.mode = mode; showEditor(b)
    }
    func togglePreview() {
        guard page == .edit, let b = active as? Buffer,b.markdown else { return }
        b.mode = b.mode == .preview ? .source : .preview
        showEditor(b)
    }
    func showQuickOpen() { showSearch(content:false) }
    func showProjectSearch() { showSearch(content:true) }
    private func showSearch(content:Bool) {
        if root == nil { choose(true) }
        guard root != nil else { return }
        deactivateDocument()
        page = content ? .find : .quick; retireUnusedPreview(); conflictBar = nil; sourceHost = nil
        let heading = content ? "项目搜索" : "快速打开"
        header(heading)
        clear(body)
        let col = stack(.vertical,[],12)
        body.pin(col,NSEdgeInsets(top:28,left:24,bottom:16,right:24))
        fillRow(label(heading,22,Ink.text,.semibold),in:col)
        let field = NSSearchField()
        field.font = .systemFont(ofSize:15); field.controlSize = .large
        field.placeholderString = content ? "搜索项目中的文字" : "输入文件名或部分路径"
        field.stringValue = content ? lastContentQuery : ""
        field.delegate = self
        fillRow(field,in:col); searchField = field
        let summary = label("",11,Ink.muted); fillRow(summary,in:col); searchTitle = summary
        let list = RowList(rowHeight:content ? 52 : 32)
        list.row = { [weak self] i in
            guard let self, i < self.resultHits.count else { return NSView() }
            let h = self.resultHits[i]
            let title = stack(.vertical,[label(h.path+(h.line.map { "  ·  第 \($0) 行" } ?? ""),12,Ink.text,.medium)],3)
            if h.line != nil { title.addArrangedSubview(label(h.excerpt,11,Ink.muted)) }
            return wrapped(stack(.horizontal,[glyph(fileIcon(h.url),Ink.accent,13),title,spring()],11),margins(4,10))
        }
        list.select = { [weak self] i in self?.openHit(i) }
        fillRow(list,in:col); resultList = list
        resultHits = []
        status.stringValue = roots.count > 1 ? "全部项目（\(roots.count)）" : root?.lastPathComponent ?? ""; rightStatus.stringValue = ""
        runSearch(); window.makeFirstResponder(field)
    }
    func runSearch(debounce:Bool = false) {
        guard let field = searchField,!roots.isEmpty else { return }
        resultHits = []; resultList?.reset(0)
        if page == .find {
            lastContentQuery = field.stringValue
            if lastContentQuery.isEmpty {
                search.cancel(); searchTitle?.stringValue = "输入关键词以查找文件内容"; return
            }
        }
        searchTitle?.stringValue = "正在查找…"
        search.run(roots:roots,query:field.stringValue,content:page == .find,buffers:docs.compactMap { $0 as? Buffer },debounce:debounce) { [weak self] hits,error in
            guard let self else { return }
            self.resultHits = hits; self.resultList?.reset(hits.count)
            self.searchTitle?.stringValue = error ?? (hits.isEmpty ? "没有匹配结果" : hits.count == 1000 ? "显示前 1,000 条结果" : "\(hits.count) 条结果")
        }
    }
    func openHit(_ i:Int) {
        guard resultHits.indices.contains(i) else { return }
        openFile(resultHits[i].url,line:resultHits[i].line)
    }
    func controlTextDidChange(_ obj:Notification) { runSearch(debounce:true) }
    func control(_ control:NSControl,textView:NSTextView,doCommandBy selector:Selector) -> Bool {
        guard let list = resultList else { return false }
        if selector == #selector(NSResponder.insertNewline(_:)) { openHit(max(0,list.table.selectedRow)); return true }
        if selector == #selector(NSResponder.moveDown(_:)) || selector == #selector(NSResponder.moveUp(_:)) {
            guard !resultHits.isEmpty else { return true }
            let delta = selector == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            let i = min(max(0,list.table.selectedRow+delta),resultHits.count-1)
            list.table.selectRowIndexes(IndexSet(integer:i),byExtendingSelection:false)
            list.table.selectionHighlightStyle = .regular; list.table.scrollRowToVisible(i)
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            if let b = active { showEditor(b) } else { showBrowse(folder) }
            return true
        }
        return false
    }
    func alert(_ text:String) {
        let a = NSAlert(); a.messageText = text; a.addButton(withTitle:"好"); a.runModal()
    }
    func resolve(_ b:Buffer) {
        guard let u = b.url else { return }
        let disk: TextFile?
        do { disk = FileManager.default.fileExists(atPath:u.path) ? try TextFile.read(u) : nil }
        catch { alert(error.localizedDescription); return }
        let a = NSAlert()
        a.messageText = disk == nil ? "磁盘上的文件已移除" : "比较外部修改"
        a.informativeText = "选择要保留的版本。保留编辑内容后，可用 ⌘S 写入磁盘。"
        let columns = stack(.horizontal,[],10)
        for (title,txt) in [("磁盘版本",disk?.text ?? "（已移除）"),("编辑器版本",b.source.string)] {
            let v = NSTextView(); v.isEditable = false; v.isRichText = false
            v.font = .monospacedSystemFont(ofSize:11,weight:.regular); v.string = txt
            let s = scroll(v); s.width(250); s.height(170)
            columns.addArrangedSubview(stack(.vertical,[label(title,12,Ink.muted),s],4))
        }
        columns.frame = NSRect(x:0,y:0,width:510,height:194)
        a.accessoryView = columns
        a.addButton(withTitle:"取消"); a.addButton(withTitle:"保留编辑内容")
        if disk != nil { a.addButton(withTitle:"载入磁盘版本") }
        let response = a.runModal()
        if response == .alertSecondButtonReturn {
            b.baseline = disk?.digest
            if let disk { b.file = disk }
            b.dirty = disk?.text != b.source.string
            b.conflict = false
        } else if response == .alertThirdButtonReturn,let disk { b.load(disk) }
        updateStatus()
    }
    @discardableResult func saveActive(as copy:Bool = false) -> Bool {
        guard page == .edit,let b = active as? Buffer else { return false }
        var target = b.url, expected = b.baseline
        if copy || target == nil {
            let p = NSSavePanel()
            p.nameFieldStringValue = b.url?.lastPathComponent ?? b.untitled+".txt"
            p.directoryURL = b.url?.deletingLastPathComponent() ?? folder
            if p.runModal() != .OK { return false }
            #if FOLIO_STORE
            if let url = p.url { storeAccess.accept(url) }
            #endif
            target = p.url?.standardizedFileURL.resolvingSymlinksInPath()
            if let target, docs.contains(where:{$0 !== b && $0.url == target}) {
                alert("此文件已在另一个标签页中打开。"); return false
            }
            if target != b.url,let target {
                do { expected = try TextFile.diskDigest(target) }
                catch { alert(error.localizedDescription); return false }
            }
        }
        guard let target else { return false }
        do {
            let wasMarkdown = b.markdown
            try b.save(to:target,expected:expected)
            #if FOLIO_STORE
            storeAccess.remember(target)
            #endif
            if previewTab === b { previewTab = nil }
            if b.markdown && !wasMarkdown { b.mode = .preview }
            childCache.removeAll(); treeDirty = true; showEditor(b); return true
        } catch FileProblem.conflict { b.conflict = true; updateStatus(); resolve(b) }
        catch { alert(error.localizedDescription) }
        return false
    }
    func mayClose(_ document:WorkspaceDocument) -> Bool {
        guard let b = document as? Buffer else { return true }
        guard b.dirty || (b.conflict && b.missing) else { return true }
        window.makeKeyAndOrderFront(nil)
        showEditor(b)
        let a = NSAlert(); a.messageText = "保存“\(b.title)”的修改？"
        a.addButton(withTitle:"保存"); a.addButton(withTitle:"取消"); a.addButton(withTitle:"放弃修改")
        switch a.runModal() {
        case .alertFirstButtonReturn: return saveActive()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }
    private func removeTab(_ b:WorkspaceDocument) {
        if previewTab === b { previewTab = nil }
        (b as? AudioDocument)?.pause()
        tabViews.removeValue(forKey:ObjectIdentifier(b))?.removeFromSuperview()
        docs.removeAll { $0 === b }; (b as? Buffer)?.changed = nil
    }
    func closeBuffer(_ b:WorkspaceDocument) {
        guard mayClose(b) else { return }
        removeTab(b)
        if active === b { active = docs.last }
        if let active { showEditor(active) } else { showBrowse(folder) }
        updateWatches()
    }
    func mayQuit() -> Bool {
        if windowClosed { return true }
        let selected = active
        guard docs.allSatisfy({ mayClose($0) }) else { return false }
        var state: [String:Any] = ["paths":docs.compactMap { $0.url?.path }]
        state["selected"] = selected?.url?.path
        state["preview"] = previewTab?.url?.path
        #if FOLIO_STORE
        let restoredItems = roots + docs.compactMap(\.url)
        for url in restoredItems { storeAccess.remember(url) }
        let saved = projectDefaults?.stringArray(forKey:projectPathsKey) ?? []
        storeAccess.keepBookmarks(for:Set(saved + restoredItems.map(\.path)))
        #endif
        projectDefaults?.set(state,forKey:tabsKey)
        return true
    }
    func windowShouldClose(_ sender:NSWindow) -> Bool {
        mayQuit()
    }
    func windowWillClose(_ notification: Notification) {
        windowClosed = true
        search.cancel()
        watches.set([])
        (active as? AudioDocument)?.pause()
        docs.removeAll()
    }
    func windowDidBecomeKey(_ notification: Notification) {
        for b in docs { b.reconcile() }
        updateStatus()
    }
}
