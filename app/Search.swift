import Foundation

struct Hit {
    var url: URL
    var path: String
    var line: Int?
    var excerpt: String = ""
}
final class SearchService {
    private var stamp = UUID()
    private var process: Process?
    private var delay: DispatchWorkItem?
    func cancel() {
        stamp = UUID()
        delay?.cancel(); delay = nil
        if let p = process, p.isRunning { p.terminate() }
        process = nil
    }
    func run(roots: [URL], query: String, content: Bool, buffers: [Buffer], debounce:Bool = false, done: @escaping ([Hit],String?) -> Void) {
        cancel()
        guard let directory = roots.first else { done([],nil); return }
        let key = stamp
        let needle = query.lowercased()
        let prefixes = roots.sorted { $0.path.count > $1.path.count }.map { root in
            let name = root.lastPathComponent
            let prefix = root.path == "/" ? "/" : root.path + "/"
            let duplicate = roots.contains { $0 != root && $0.lastPathComponent == name }
            let label = roots.count == 1 ? "" : (duplicate ? root.path : name) + "/"
            return (prefix,prefix.count,label)
        }
        func displayPath(_ path:String) -> String {
            for (prefix,length,label) in prefixes where path.hasPrefix(prefix) {
                return label + path.dropFirst(length)
            }
            return path
        }
        let paths = roots.map(\.path)
        let files = ["--files","--null","--"] + paths
        var drafts = [String:String]()
        func searchContents(allowedDrafts:Set<String>) {
            var hits = [Hit]()
            var seen = [URL:Set<Int>]()
            // NUL terminates the filename even when it contains colons or line breaks.
            // Ask rg for a bounded line preview, without a JSON object for each occurrence.
            var awaitingPath = true
            var matchPath: String?
            let arguments = ["--with-filename","--no-heading","--line-number","--null","--color=never",
                             "--max-count=1000","--trim","--max-columns=8192","--max-columns-preview","-i","-F","--",query] + paths
            scan(directory,arguments,separator:{ awaitingPath ? 0 : 10 },key:key,prepare:{
                for absolute in allowedDrafts.sorted() {
                    let url = URL(fileURLWithPath:absolute,isDirectory:false)
                    guard let text = drafts[absolute], hits.count < 1000 else { break }
                    let path = projectPath(for:url,in:roots)
                    var number = 0
                    text.enumerateLines { line,stop in
                        number += 1
                        if line.range(of:query,options:[.caseInsensitive,.literal]) != nil {
                            hits.append(Hit(url:url,path:path,line:number,excerpt:String(line.trimmingCharacters(in:.whitespaces).prefix(250))))
                        }
                        stop = hits.count >= 1000
                    }
                }
            },limitReached:{ hits.count >= 1000 },read:{ data in
                if awaitingPath {
                    matchPath = String(data:data,encoding:.utf8)
                    awaitingPath = false
                    return
                }
                awaitingPath = true
                guard let path = matchPath, drafts[path] == nil, let colon = data.firstIndex(of:58),
                      let line = Int(String(decoding:data[..<colon],as:UTF8.self)),
                      let text = String(data:data[(colon+1)...],encoding:.utf8) else { return }
                let url = URL(fileURLWithPath:path,isDirectory:false)
                guard seen[url,default:[]].insert(line).inserted else { return }
                hits.append(Hit(url:url,path:displayPath(url.path),line:line,excerpt:String(text.trimmingCharacters(in:.whitespacesAndNewlines).prefix(250))))
            },finish:{ error in
                done(hits.sorted { $0.path == $1.path ? ($0.line ?? 0) < ($1.line ?? 0) : $0.path < $1.path },error)
            })
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.stamp == key else { return }
            self.delay = nil
            drafts = Dictionary(uniqueKeysWithValues: buffers.compactMap { buffer -> (String,String)? in
                guard content, buffer.dirty, let url = buffer.url, projectRoot(for:url,in:roots) != nil else { return nil }
                return (url.standardizedFileURL.path,buffer.source.string)
            })
            if content && drafts.isEmpty { searchContents(allowedDrafts:[]); return }
            var allowed = Set<String>()
            // Keep one bounded batch beyond the best 1000. Overlapping project roots can emit duplicates.
            typealias Candidate = (rank:Int, path:String)
            var candidates = [String:Candidate]()
            var cutoff: Candidate?
            func precedes(_ a:Candidate,_ b:Candidate) -> Bool {
                a.rank == b.rank ? a.path < b.path : a.rank < b.rank
            }
            func best() -> [(key:String,value:Candidate)] {
                Array(candidates.sorted { lhs,rhs in
                    precedes(lhs.value,rhs.value)
                }.prefix(1000))
            }
            self.scan(directory,files,separator:{ 0 },key:key,read:{ bytes in
                let absolute = String(decoding:bytes,as:UTF8.self)
                if content {
                    if drafts[absolute] != nil { allowed.insert(absolute) }
                } else {
                    let path = displayPath(absolute)
                    guard let rank = Self.rank(path,needle) else { return }
                    let candidate = (rank,path)
                    if let cutoff, precedes(cutoff,candidate) { return }
                    candidates[absolute] = candidate
                    if candidates.count == 2000 {
                        let winners = best()
                        cutoff = winners.last?.value
                        candidates = Dictionary(uniqueKeysWithValues:winners)
                    }
                }
            },finish:{ error in
                if content, error == nil { searchContents(allowedDrafts:allowed); return }
                done(best().map { Hit(url:URL(fileURLWithPath:$0.key,isDirectory:false),path:$0.value.path) },error)
            })
        }
        if debounce {
            delay = work
            DispatchQueue.main.asyncAfter(deadline:.now()+0.10,execute:work)
        } else { work.perform() }
    }

    private func scan(_ directory:URL,_ arguments:[String],separator:@escaping ()->UInt8,key:UUID,
                      prepare:@escaping ()->Void = {},limitReached:(()->Bool)? = nil,
                      read:@escaping (Data)->Void,finish:@escaping (String?)->Void) {
        let p = Process(), output = Pipe(), errors = Pipe()
        p.currentDirectoryURL = directory
        p.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/rg")
        p.arguments = ["--no-config","--hidden","--glob","!.git","--no-require-git"] + arguments
        p.standardOutput = output; p.standardError = errors
        process = p
        do { try p.run() } catch { finish(error.localizedDescription); return }
        DispatchQueue.global(qos:.userInitiated).async {
            let group = DispatchGroup()
            final class ErrorBox { var message = "" }
            let box = ErrorBox()
            group.enter()
            DispatchQueue.global().async {
                var diagnostic = Data()
                while true {
                    let chunk = autoreleasepool { errors.fileHandleForReading.availableData }
                    if chunk.isEmpty { break }
                    diagnostic.append(chunk.prefix(8192-diagnostic.count))
                }
                box.message = String(decoding:diagnostic,as:UTF8.self)
                group.leave()
            }
            prepare()
            var limited = false
            var pending = Data()
            while true {
                let chunk = autoreleasepool { output.fileHandleForReading.availableData }
                if chunk.isEmpty { break }
                if limited { continue }
                autoreleasepool {
                    var start = chunk.startIndex
                    while let end = chunk[start...].firstIndex(of:separator()) {
                        if pending.isEmpty {
                            read(chunk[start..<end])
                        } else {
                            pending.append(chunk[start..<end])
                            read(pending); pending = Data()
                        }
                        if limitReached?() == true {
                            limited = true
                            if p.isRunning { p.terminate() }
                            return
                        }
                        start = end + 1
                    }
                    pending.append(chunk[start...])
                }
            }
            if !limited && !pending.isEmpty { read(pending) }
            p.waitUntilExit(); group.wait()
            let error = !limited && p.terminationStatus > 1 ? box.message : nil
            DispatchQueue.main.async {
                guard self.stamp == key else { return }
                self.process = nil
                finish(error)
            }
        }
    }
    private static func rank(_ path: String,_ query: String) -> Int? {
        if query.isEmpty { return path.lowercased().count }
        let s = path.lowercased(), q = query
        let name = s.lastIndex(of:"/").map { s[s.index(after:$0)...] } ?? s[...]
        if name.hasPrefix(q) { return s.count }
        if s.contains(q) { return 1000+s.count }
        var rest = s[...]
        for c in q {
            guard let i = rest.firstIndex(of:c) else { return nil }
            rest = rest[rest.index(after:i)...]
        }
        return 2000+s.count
    }
}
