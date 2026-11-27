import AppKit
#if !FOLIO_STORE
import Sparkle
#endif

final class Application: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private(set) var editor: Workspace!
    private var pendingURLs = [URL]()
    #if !FOLIO_STORE
    private let updates = SPUStandardUpdaterController(startingUpdater:false,updaterDelegate:nil,userDriverDelegate:nil)
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        ThemeButton.restorePreference()
        #if FOLIO_TEST || FOLIO_BENCH
        let profile = ProcessInfo.processInfo.environment["FOLIO_TEST_PROFILE"]
        editor = Workspace(projectDefaults:profile.flatMap { UserDefaults(suiteName:$0) })
        #else
        editor = Workspace()
        #endif
        #if !FOLIO_STORE && !FOLIO_TEST && !FOLIO_BENCH
        updates.startUpdater()
        #endif
        menus()
        NotificationCenter.default.addObserver(self,selector:#selector(systemLanguageChanged),
                                               name:NSLocale.currentLocaleDidChangeNotification,object:nil)
        editor.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps:true)
        let paths = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }.map { URL(fileURLWithPath:$0) }
        editor.open(pendingURLs + paths)
        pendingURLs.removeAll()
        #if FOLIO_BENCH
        Timer.scheduledTimer(withTimeInterval:0.3,repeats:false) { _ in runPerformance(self.editor) }
        #elseif FOLIO_TEST
        Timer.scheduledTimer(withTimeInterval:0.2,repeats:false) { _ in runIntegration(self.editor) }
        #endif
    }
    func application(_ sender:NSApplication,open urls:[URL]) {
        guard let editor else { pendingURLs += urls; return }
        if editor.window.isMiniaturized { editor.window.deminiaturize(nil) }
        editor.window.makeKeyAndOrderFront(nil)
        editor.open(urls)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender:NSApplication) -> NSApplication.TerminateReply {
        editor?.mayQuit() != false ? .terminateNow : .terminateCancel
    }
    @objc func newDoc() { editor.newBuffer() }
    @objc func openFile() { editor.choose(false) }
    @objc func openFolder() { editor.choose(true) }
    @objc func save() { editor.saveActive() }
    @objc func saveAs() { editor.saveActive(as:true) }
    @objc func closeTab() {
        if editor.page == .edit,let b = editor.active { editor.closeBuffer(b) } else { editor.window.performClose(nil) }
    }
    @objc func largerType() { editor.changeFontSize(by:1) }
    @objc func smallerType() { editor.changeFontSize(by:-1) }
    @objc func findInFile(_ sender:NSMenuItem) {
        guard editor.page == .edit, let buffer = editor.active as? Buffer else { return }
        if buffer.markdown && buffer.mode == .preview {
            buffer.mode = .split
            editor.showEditor(buffer)
        }
        let source = buffer.source
        editor.window.makeFirstResponder(source)
        source.performTextFinderAction(sender)
    }
    @objc func projectSearch() { editor.showProjectSearch() }
    @objc func quick() { editor.showQuickOpen() }
    @objc func preview() { editor.togglePreview() }
    @objc func browse() { editor.showBrowse(editor.folder) }
    @objc func chooseLanguage(_ sender:NSMenuItem) {
        guard let code = sender.representedObject as? String, let choice = AppLanguage(rawValue:code) else { return }
        Localization.select(choice)
        refreshLanguage()
    }
    @objc private func systemLanguageChanged() {
        if Localization.choice == .system { refreshLanguage() }
    }
    private func refreshLanguage() {
        let changed = Localization.refresh()
        menus()
        if changed { editor.refreshLanguage() }
    }
    func validateMenuItem(_ menuItem:NSMenuItem) -> Bool {
        if menuItem.action == #selector(findInFile(_:)) {
            return editor?.page == .edit && editor?.active is Buffer && NSApp.modalWindow == nil
        }
        if [#selector(save), #selector(saveAs), #selector(largerType), #selector(smallerType)].contains(where:{ $0 == menuItem.action }) {
            return editor?.page == .edit && editor?.active is Buffer
        }
        return true
    }
    func menus() {
        let top = NSMenu(); NSApp.mainMenu = top
        func menu(_ title:String) -> NSMenu {
            let item = NSMenuItem(); top.addItem(item)
            let m = NSMenu(title:title); item.submenu = m; return m
        }
        func item(_ m:NSMenu,_ name:String,_ action:Selector,_ key:String,_ modifiers:NSEvent.ModifierFlags = .command,_ target:AnyObject? = nil) -> NSMenuItem {
            let i = m.addItem(withTitle:name,action:action,keyEquivalent:key)
            i.keyEquivalentModifierMask = modifiers; i.target = target
            return i
        }
        let app = menu("Folio")
        let language = NSMenuItem(title:L("Language Settings"),action:nil,keyEquivalent:"")
        app.addItem(language)
        let options = NSMenu(title:language.title)
        language.submenu = options
        for choice in AppLanguage.allCases {
            let option = item(options,choice.menuTitle,#selector(chooseLanguage(_:)),"",[],self)
            option.representedObject = choice.rawValue
            option.state = choice == Localization.choice ? .on : .off
        }
        #if !FOLIO_STORE
        _ = item(app,L("Check for Updates…"),#selector(SPUStandardUpdaterController.checkForUpdates(_:)),"",[],updates)
        app.addItem(.separator())
        #endif
        _ = item(app,L("Quit Folio"),#selector(NSApplication.terminate(_:)),"q")
        let f = menu(L("File"))
        _ = item(f,L("New File"),#selector(newDoc),"n",.command,self)
        _ = item(f,L("Open File…"),#selector(openFile),"o",.command,self)
        _ = item(f,L("Open Project…"),#selector(openFolder),"o",[.command,.shift],self)
        f.addItem(.separator())
        _ = item(f,L("Save"),#selector(save),"s",.command,self)
        _ = item(f,L("Save As…"),#selector(saveAs),"s",[.command,.shift],self)
        _ = item(f,L("Close Tab"),#selector(closeTab),"w",.command,self)
        let e = menu(L("Edit"))
        for (name,sel,key) in [(L("Undo"),"undo:","z"),(L("Redo"),"redo:","Z"),(L("Cut"),"cut:","x"),(L("Copy"),"copy:","c"),(L("Paste"),"paste:","v"),(L("Select All"),"selectAll:","a")] {
            _ = item(e,name,NSSelectorFromString(sel),key,key=="Z" ? [.command,.shift] : .command)
        }
        e.addItem(.separator())
        _ = item(e,L("Select Next Occurrence"),#selector(SourceView.selectNextOccurrence(_:)),"d")
        _ = item(e,L("Select All Occurrences"),#selector(SourceView.selectAllOccurrences(_:)),"L",[.command,.shift])
        _ = item(e,L("Select Line"),#selector(SourceView.selectCurrentLine(_:)),"l")
        let findActions: [(String,String,NSEvent.ModifierFlags,NSTextFinder.Action)] = [
            (L("Find"),"f",.command,.showFindInterface),
            (L("Find Next"),"g",.command,.nextMatch),
            (L("Find Previous"),"G",[.command,.shift],.previousMatch),
            (L("Find and Replace"),"h",[.command,.option],.showReplaceInterface)
        ]
        for (name,key,modifiers,action) in findActions {
            item(e,name,#selector(findInFile(_:)),key,modifiers,self).tag = action.rawValue
        }
        let v = menu(L("View"))
        _ = item(v,L("Increase Text Size"),#selector(largerType),"+",.command,self)
        let equal = item(v,L("Increase Text Size"),#selector(largerType),"=",.command,self)
        equal.isHidden = true; equal.allowsKeyEquivalentWhenHidden = true
        _ = item(v,L("Decrease Text Size"),#selector(smallerType),"-",.command,self)
        _ = item(v,L("Search Project"),#selector(projectSearch),"f",[.command,.shift],self)
        _ = item(v,L("Quick Open"),#selector(quick),"p",.command,self)
        _ = item(v,L("Markdown Source / Preview"),#selector(preview),"e",.command,self)
        _ = item(v,L("Project Overview"),#selector(browse),"1",.command,self)
        let windows = menu(L("Window"))
        NSApp.windowsMenu = windows
    }
}
Localization.refresh()
let application = NSApplication.shared
let delegate = Application()
application.setActivationPolicy(.regular)
application.delegate = delegate
application.run()
