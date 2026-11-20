#if FOLIO_STORE
import Foundation

/// Keep grants for selected folders and standalone documents across sandboxed launches.
final class StoreFileAccess {
    private let defaults = UserDefaults.standard
    private let key = "FolioScopedBookmarks"
    private var bookmarks: [String:Data]
    private var active = [String:URL]()

    init() { bookmarks = defaults.dictionary(forKey:key) as? [String:Data] ?? [:] }

    private func path(_ url:URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }

    func accept(_ url:URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        let name = path(url)
        if active[name] == nil { active[name] = url }
        else { url.stopAccessingSecurityScopedResource() }
    }

    func remember(_ url:URL) {
        let name = path(url)
        guard bookmarks[name] == nil,
              let data = try? url.bookmarkData(options:.withSecurityScope,includingResourceValuesForKeys:nil,relativeTo:nil) else { return }
        bookmarks[name] = data
        defaults.set(bookmarks,forKey:key)
    }

    func resolve(_ url:URL) -> URL {
        let name = url.standardizedFileURL.path
        guard let data = bookmarks[name] else { return url }
        var stale = false
        guard let resolved = try? URL(resolvingBookmarkData:data,options:[.withSecurityScope,.withoutUI],
                                     relativeTo:nil,bookmarkDataIsStale:&stale) else { return url }
        accept(resolved)
        if stale, let fresh = try? resolved.bookmarkData(options:.withSecurityScope,includingResourceValuesForKeys:nil,relativeTo:nil) {
            bookmarks[name] = fresh
            defaults.set(bookmarks,forKey:key)
        }
        return resolved
    }

    func releaseUnused(keeping urls:[URL]) {
        let needed = urls.map(path)
        for (name,url) in active where !needed.contains(where:{ $0 == name || $0.hasPrefix(name == "/" ? "/" : name+"/") }) {
            url.stopAccessingSecurityScopedResource()
            active.removeValue(forKey:name)
        }
    }

    func keepBookmarks(for paths:Set<String>) {
        bookmarks = bookmarks.filter { paths.contains($0.key) }
        defaults.set(bookmarks,forKey:key)
    }

    deinit { for url in active.values { url.stopAccessingSecurityScopedResource() } }
}
#endif
