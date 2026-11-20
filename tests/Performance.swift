import AppKit
import Darwin

// Benchmarks use the same window, document, search and file-watching paths as a normal launch.
func runPerformance(_ e:Workspace) {
    setlinebuf(stdout)
    let env = ProcessInfo.processInfo.environment
    guard let path = env["FOLIO_BENCH_ROOT"] else { exit(2) }
    let root = URL(fileURLWithPath:path,isDirectory:true)
    func file(_ name:String) -> URL { root.appendingPathComponent(name) }
    func settle(_ seconds:Double) { RunLoop.current.run(until:Date().addingTimeInterval(seconds)) }
    func footprint() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue:info)/MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to:&info) { p in
            p.withMemoryRebound(to:integer_t.self,capacity:Int(count)) { task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&count) }
        }
        precondition(result == KERN_SUCCESS)
        return Double(info.phys_footprint)/1048576
    }
    func measure(_ name:String,_ work:()->Void) {
        let start = ProcessInfo.processInfo.systemUptime
        autoreleasepool { work(); e.window.contentView?.layoutSubtreeIfNeeded() }
        let ms = (ProcessInfo.processInfo.systemUptime-start)*1000
        settle(0.25)
        print(String(format:"BENCH %@ %.2f %.2f",name,ms,footprint()))
    }
    measure("idle") {}
    measure("workspace") { e.open([root]) }
    measure("large") { e.open([file("long.txt")]) }
    measure("tabs") {
        for n in 0..<8 {
            autoreleasepool { e.open([file("code-\(n).swift")]) }
        }
    }
    measure("reconcile") { for _ in 0..<3 { e.diskChanged() } }
    measure("quick") {
        e.showQuickOpen()
        let stop = Date().addingTimeInterval(45)
        while e.resultHits.count < 1000 && Date() < stop { settle(0.01) }
        precondition(e.resultHits.count == 1000)
    }
    measure("find") {
        e.showProjectSearch(); e.searchField!.stringValue = "unique-folio-benchmark-line"; e.runSearch()
        let stop = Date().addingTimeInterval(45)
        while e.resultHits.count != 1 && Date() < stop { settle(0.01) }
        precondition(e.resultHits.count == 1)
    }
    let code = e.docs.compactMap { $0 as? Buffer }.last!
    e.showEditor(code)
    measure("edit") {
        let range = NSRange(location:0,length:0)
        for _ in 0..<8 { code.source.insertText("x",replacementRange:range) }
        code.refreshColors()
    }
    measure("markdown") {
        for n in 0..<6 { autoreleasepool { e.open([file("notes-\(n).md")]) } }
        var ready = false
        let stop = Date().addingTimeInterval(20)
        while !ready && Date() < stop {
            settle(0.05)
            e.preview?.web.evaluateJavaScript("document.querySelector('main')?.innerText.startsWith('Notes 5')") { value,_ in ready = value as? Bool == true }
        }
        precondition(ready)
    }
    print("BENCHMARK COMPLETE")
    exit(0)
}
