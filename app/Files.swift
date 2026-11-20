import Cocoa
import Compression

import CryptoKit

struct FileRevision: Equatable {
    let size: Int64
    let inode: UInt64
    let device: Int32
    let modifiedSeconds, modifiedNanoseconds, changedSeconds, changedNanoseconds: Int

    init(_ url: URL) throws {
        var attributes = stat()
        guard stat(url.path,&attributes) == 0 else { throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno)) }
        size = attributes.st_size; inode = attributes.st_ino; device = attributes.st_dev
        modifiedSeconds = attributes.st_mtimespec.tv_sec
        modifiedNanoseconds = attributes.st_mtimespec.tv_nsec
        changedSeconds = attributes.st_ctimespec.tv_sec
        changedNanoseconds = attributes.st_ctimespec.tv_nsec
    }
}

enum FileProblem: LocalizedError {
    case unsupported, large, conflict
    var errorDescription: String? {
        switch self {
        case .unsupported: return "此文件不是支持的 UTF-8 或 UTF-16 文本。"
        case .large: return "此版本的编辑上限为每个文件 32 MB。"
        case .conflict: return "磁盘内容已变化，请先处理外部修改。"
        }
    }
}
// Inactive tabs keep an immutable snapshot even if the original file is replaced or deleted.
private enum TextSnapshot {
    case plain(String)
    case packed(Data, byteCount:Int)

    var string: String {
        switch self {
        case .plain(let value): return value
        case let .packed(data,count):
            return String(unsafeUninitializedCapacity:count) { output in
                data.withUnsafeBytes { bytes in
                    let written = compression_decode_buffer(output.baseAddress!,count,
                        bytes.bindMemory(to:UInt8.self).baseAddress!,bytes.count,nil,COMPRESSION_LZ4)
                    precondition(written == count)
                    return written
                }
            }
        }
    }
    mutating func compact() {
        guard case .plain(var text) = self, text.utf8.count >= 128*1024 else { return }
        text.withUTF8 { bytes in
            // Bound scratch space and keep the compressed copy only when it saves at least half.
            let capacity = bytes.count / 2
            let scratch = UnsafeMutablePointer<UInt8>.allocate(capacity:capacity)
            defer { scratch.deallocate() }
            let length = compression_encode_buffer(scratch,capacity,bytes.baseAddress!,bytes.count,nil,COMPRESSION_LZ4)
            if length > 0 { self = .packed(Data(bytes:scratch,count:length),byteCount:bytes.count) }
        }
    }
    mutating func expand() {
        if case .packed = self { self = .plain(string) }
    }
}
struct TextFile {
    let digest: SHA256.Digest
    var revision: FileRevision?
    private var snapshot: TextSnapshot
    var text: String { snapshot.string }
    let utf16Length: Int
    var encoding: String.Encoding = .utf8
    var bom = Data()
    var newline = "\n"
    init(_ bytes: Data) throws {
        digest = SHA256.hash(data:bytes)
        if bytes.starts(with: [0xff,0xfe]) { encoding = .utf16LittleEndian; bom = Data([0xff,0xfe]) }
        else if bytes.starts(with: [0xfe,0xff]) { encoding = .utf16BigEndian; bom = Data([0xfe,0xff]) }
        else if bytes.starts(with: [0xef,0xbb,0xbf]) { bom = Data([0xef,0xbb,0xbf]) }
        let payload = bytes.dropFirst(bom.count)
        guard var value = String(data:payload,encoding:encoding), !value.utf8.contains(0) else { throw FileProblem.unsupported }
        let normalized: String
        if value.utf8.contains(13) {
            var hasCRLF = false
            normalized = value.withUTF8 { bytes in
                String(unsafeUninitializedCapacity:bytes.count) { out in
                    var written = 0, previousCR = false
                    for byte in bytes {
                        if byte == 10 && previousCR {
                            hasCRLF = true
                        } else {
                            out[written] = byte == 13 ? 10 : byte
                            written += 1
                        }
                        previousCR = byte == 13
                    }
                    return written
                }
            }
            newline = hasCRLF ? "\r\n" : "\r"
        } else { normalized = value }
        snapshot = .plain(normalized)
        utf16Length = normalized.utf16.count
    }
    mutating func compact() { snapshot.compact() }
    mutating func expand() { snapshot.expand() }
    func encode(_ value: String) -> Data {
        let normalized = newline == "\n" ? value : value.replacingOccurrences(of:"\n",with:newline)
        let data = normalized.data(using:encoding)!
        return bom.isEmpty ? data : bom + data
    }
    static func read(_ url:URL, revision:FileRevision? = nil) throws -> TextFile {
        let stamp = try revision ?? FileRevision(url)
        guard stamp.size <= 32 * 1024 * 1024 else { throw FileProblem.large }
        let data = try Data(contentsOf:url)
        guard data.count <= 32 * 1024 * 1024 else { throw FileProblem.large }
        var file = try TextFile(data)
        file.revision = stamp
        return file
    }
    static func diskDigest(_ url:URL) throws -> SHA256.Digest? {
        do {
            // Stream the validation pass: saving over an existing file should not allocate its whole contents.
            let handle = try FileHandle(forReadingFrom:url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount:256 * 1024), !chunk.isEmpty { hasher.update(data:chunk) }
            return hasher.finalize()
        } catch let error as NSError where (error.domain == NSCocoaErrorDomain && [NSFileReadNoSuchFileError,NSFileNoSuchFileError].contains(error.code)) || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT)) {
            return nil
        }
    }
}
func children(_ dir: URL) -> [URL] {
    let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? []
    // Keep the same path spelling as the sidebar root (e.g. /var vs /private/var).
    let entries = urls.compactMap { url -> (name:String, directory:Bool)? in
        let name = url.lastPathComponent
        guard name != ".git", name != ".DS_Store" else { return nil }
        return (name,isFolder(url))
    }
    return entries.sorted { a,b in
        if a.directory != b.directory { return a.directory }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }.map { dir.appendingPathComponent($0.name,isDirectory:$0.directory) }
}
func isFolder(_ u: URL) -> Bool { (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
func inside(_ u: URL, _ root: URL) -> Bool {
    let base = root.standardizedFileURL.path
    return u.standardizedFileURL.path == base || u.standardizedFileURL.path.hasPrefix(base == "/" ? "/" : base + "/")
}
func relative(_ u: URL, to root: URL?) -> String {
    guard let root, inside(u,root) else { return u.path }
    return u.pathComponents.dropFirst(root.pathComponents.count).joined(separator: "/")
}

func projectRoot(for url:URL,in roots:[URL]) -> URL? {
    roots.filter { inside(url,$0) }.max { $0.pathComponents.count < $1.pathComponents.count }
}
func projectPath(for url:URL,in roots:[URL]) -> String {
    guard let root = projectRoot(for:url,in:roots) else { return url.path }
    let path = relative(url,to:root)
    if roots.count == 1 { return path }
    let duplicateName = roots.contains { $0 != root && $0.lastPathComponent == root.lastPathComponent }
    return (duplicateName ? root.path : root.lastPathComponent) + "/" + path
}

// Observe both the file inode (in-place writes) and its parent (atomic replacement).
final class FileWatches {
    // Retire descriptors even while the UI is busy switching preview tabs.
    private let queue = DispatchQueue(label:"Folio.file-watches")
    private var sources = [String: DispatchSourceFileSystemObject]()
    private var pending: DispatchWorkItem?
    private var changedPaths = Set<String>()
    var onChange: ((Set<String>) -> Void)?
    func set(_ urls: [URL]) {
        let paths = Set(urls.map(\.path))
        for key in Array(sources.keys) where !paths.contains(key) { sources.removeValue(forKey:key)?.cancel() }
        for path in paths where sources[path] == nil {
            let fd = Darwin.open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write,.rename,.delete,.extend,.attrib,.revoke], queue: queue)
            s.setCancelHandler { close(fd) }
            s.setEventHandler { [weak self, weak watched = s as AnyObject] in
                guard let source = watched as? DispatchSourceFileSystemObject else { return }
                let replaced = !source.data.intersection([.rename,.delete,.revoke]).isEmpty
                DispatchQueue.main.async { [weak self] in
                    guard let self, let current = self.sources[path],
                          current as AnyObject === source as AnyObject else { return }
                    if replaced {
                        self.sources.removeValue(forKey:path)?.cancel()
                    }
                    self.changedPaths.insert(path)
                    self.pending?.cancel()
                    let job = DispatchWorkItem { [weak self] in
                        guard let self else { return }
                        let changed = self.changedPaths
                        self.changedPaths.removeAll()
                        self.pending = nil
                        self.onChange?(changed)
                    }
                    self.pending = job
                    DispatchQueue.main.asyncAfter(deadline: .now()+0.12, execute: job)
                }
            }
            sources[path] = s
            s.resume()
        }
    }
    deinit { for s in sources.values { s.cancel() } }
}
