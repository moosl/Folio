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
    @objc func projectSearch() { editor.showProjectSearch() }
    @objc func quick() { editor.showQuickOpen() }
    @objc func preview() { editor.togglePreview() }
    @objc func browse() { editor.showBrowse(editor.folder) }
    func validateMenuItem(_ menuItem:NSMenuItem) -> Bool {
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
        #if !FOLIO_STORE
        _ = item(app,"检查更新…",#selector(SPUStandardUpdaterController.checkForUpdates(_:)),"",[],updates)
        app.addItem(.separator())
        #endif
        _ = item(app,"退出 Folio",#selector(NSApplication.terminate(_:)),"q")
        let f = menu("文件")
        _ = item(f,"新建文件",#selector(newDoc),"n",.command,self)
        _ = item(f,"打开文件…",#selector(openFile),"o",.command,self)
        _ = item(f,"打开项目…",#selector(openFolder),"o",[.command,.shift],self)
        f.addItem(.separator())
        _ = item(f,"保存",#selector(save),"s",.command,self)
        _ = item(f,"另存为…",#selector(saveAs),"s",[.command,.shift],self)
        _ = item(f,"关闭标签页",#selector(closeTab),"w",.command,self)
        let e = menu("编辑")
        for (name,sel,key) in [("撤销","undo:","z"),("重做","redo:","Z"),("剪切","cut:","x"),("复制","copy:","c"),("粘贴","paste:","v"),("全选","selectAll:","a")] {
            _ = item(e,name,NSSelectorFromString(sel),key.lowercased(),key=="Z" ? [.command,.shift] : .command)
        }
        for (name,key,tag) in [("查找","f",NSTextFinder.Action.showFindInterface),("查找和替换","h",.showReplaceInterface)] {
            let i = item(e,name,#selector(NSTextView.performTextFinderAction(_:)),key,key=="h" ? [.command,.option] : .command); i.tag = tag.rawValue
        }
        let v = menu("查看")
        _ = item(v,"放大文字",#selector(largerType),"+",.command,self)
        let equal = item(v,"放大文字",#selector(largerType),"=",.command,self)
        equal.isHidden = true; equal.allowsKeyEquivalentWhenHidden = true
        _ = item(v,"缩小文字",#selector(smallerType),"-",.command,self)
        _ = item(v,"项目搜索",#selector(projectSearch),"f",[.command,.shift],self)
        _ = item(v,"快速打开",#selector(quick),"p",.command,self)
        _ = item(v,"Markdown 源码 / 预览",#selector(preview),"e",.command,self)
        _ = item(v,"项目概览",#selector(browse),"1",.command,self)
        let windows = menu("窗口")
        NSApp.windowsMenu = windows
    }
}
let application = NSApplication.shared
let delegate = Application()
application.setActivationPolicy(.regular)
application.delegate = delegate
application.run()
