import WebKit
import UniformTypeIdentifiers
import cmark_gfm
import cmark_gfm_extensions

func renderMarkdown(_ text: String) -> String {
    struct Registry { static let ready: Void = cmark_gfm_core_extensions_ensure_registered() }
    _ = Registry.ready
    let options = Int32(CMARK_OPT_DEFAULT)
    let parser = cmark_parser_new(options)!
    defer { cmark_parser_free(parser) }
    for name in ["table","strikethrough","tasklist","autolink"] {
        cmark_parser_attach_syntax_extension(parser,cmark_find_syntax_extension(name))
    }
    let metadata = FrontMatter(text)
    let body = metadata?.body ?? text
    body.withCString { cmark_parser_feed(parser,$0,body.utf8.count) }
    let doc = cmark_parser_finish(parser)!
    defer { cmark_node_free(doc) }
    let raw = cmark_render_html(doc,options,cmark_parser_get_syntax_extensions(parser))!
    defer { free(raw) }
    return (metadata?.html ?? "") + String(cString:raw)
}

final class Assets: NSObject, WKURLSchemeHandler {
    var root: URL?
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let u = task.request.url, let root,
              u.host == "local", let type = UTType(filenameExtension:u.pathExtension),
              type.conforms(to:.image) else { task.didFailWithError(URLError(.unsupportedURL)); return }
        let file = root.appendingPathComponent(String(u.path.dropFirst())).resolvingSymlinksInPath()
        guard inside(file,root.resolvingSymlinksInPath()), let data = try? Data(contentsOf:file) else {
            task.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        task.didReceive(URLResponse(url:u,mimeType:type.preferredMIMEType ?? "application/octet-stream",expectedContentLength:data.count,textEncodingName:nil))
        task.didReceive(data)
        task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

final class Preview: NSObject, WKNavigationDelegate {
    let web: WKWebView
    let assets = Assets()
    private var fontSize = Buffer.defaultFontSize
    private var ready = false
    private var job: DispatchWorkItem?
    private let renderer: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private var generation = 0
    private var lastVersion: UInt64?
    private weak var lastDocument: Buffer?
    private var markup: String?
    private var base = "", resetScroll = false
    private var current: ObjectIdentifier?
    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(assets,forURLScheme:"folio-asset")
        web = WKWebView(frame:.zero,configuration:config)
        super.init()
        web.navigationDelegate = self
        web.loadHTMLString("""
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src folio-asset:; base-uri folio-asset:">
        <base href="folio-asset://local/"><style>
        :root{color-scheme:light dark;--bg:#fbf8f3;--fg:#3a342e;--head:#2a241f;--muted:#857a6f;--accent:#b5603a;
        --code:#f1ebe2;--line:#e7dfd3;--th:#f5f0e8;--quote:#d9b49a}
        @media (prefers-color-scheme:dark){:root{--bg:#1f1b18;--fg:#dcd3c8;--head:#f2ebe1;--muted:#a3978a;--accent:#e2a571;
        --code:#2a2521;--line:#3a332d;--th:#26211d;--quote:#8a6a52}}
        *{box-sizing:border-box}html{background:var(--bg);color:var(--fg);-webkit-font-smoothing:antialiased}
        body{margin:0 auto;padding:34px clamp(22px,5vw,56px) 96px;max-width:780px;font:15px/1.8 -apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif;overflow-wrap:anywhere}
        h1,h2,h3,h4{line-height:1.3;color:var(--head);margin:1.6em 0 .55em;letter-spacing:-.01em;font-weight:650}
        h1{font:600 2.1em/1.2 ui-serif,"New York","Songti SC",serif;letter-spacing:-.02em;margin-bottom:.6em}
        h2{font-size:1.4em;padding-bottom:.3em;border-bottom:1px solid var(--line)}h3{font-size:1.15em}
        main>:first-child{margin-top:0}a{color:var(--accent);text-decoration:none;border-bottom:1px solid color-mix(in srgb,var(--accent) 35%,transparent)}
        pre,code{font-family:ui-monospace,"SF Mono",monospace;font-size:.88em;background:var(--code);border-radius:6px}
        code{padding:2px 6px}pre{padding:16px 18px;overflow:auto;line-height:1.6;border:1px solid var(--line);border-radius:10px}pre code{padding:0;background:none}
        p{margin:.8em 0}ul,ol{padding-left:1.5em}li{margin:.25em 0}li::marker{color:var(--muted)}
        blockquote{border-left:3px solid var(--quote);margin:1.2em 0;padding:.2em 0 .2em 18px;color:var(--muted);font-style:italic}
        table{border-collapse:separate;border-spacing:0;width:100%;border:1px solid var(--line);border-radius:10px;margin:1.2em 0;font-size:.93em}
        td,th{padding:8px 14px;border-bottom:1px solid var(--line);text-align:left}td+td,th+th{border-left:1px solid var(--line)}
        tr:last-child td{border-bottom:0}th{background:var(--th);font-weight:600;color:var(--head)}
        .frontmatter{padding-bottom:1.15em;margin-bottom:1.5em;border-bottom:1px solid var(--line)}
        .frontmatter h1{font-weight:750;line-height:1.2;margin:0;text-wrap:pretty}
        .frontmatter p{margin:.75em 0 0}.frontmatter>:first-child{margin-top:0}
        .byline{font-size:.88em;color:var(--muted)}.summary{line-height:1.7;white-space:pre-line}
        .tags{display:flex;flex-wrap:wrap;gap:.45em}.tags span{border-radius:.35em;padding:.05em .5em;background:var(--code);color:var(--accent);font-size:.82em}
        hr{border:0;border-top:1px solid var(--line);margin:2em 0}img{max-width:100%;height:auto;border-radius:8px}input{accent-color:var(--accent)}
        </style></head><body><main></main></body></html>
        """,baseURL:nil)
    }
    func setFontSize(_ size:CGFloat) {
        fontSize = size
        guard ready else { return }
        web.callAsyncJavaScript("document.body.style.fontSize = size + 'px'",arguments:["size":15 * size / Buffer.defaultFontSize],in:nil,in:.page,completionHandler:nil)
    }
    func show(_ doc: Buffer, root: URL?) {
        if fontSize != doc.fontSize { setFontSize(doc.fontSize) }
        let identity = ObjectIdentifier(doc)
        resetScroll = resetScroll || current != identity
        current = identity
        let parent = doc.url?.deletingLastPathComponent()
        assets.root = parent.flatMap { p in root.flatMap { inside(p,$0) ? $0 : nil } ?? p }
        let folder = parent.flatMap { p in assets.root.map { relative(p,to:$0) } } ?? ""
        var parts = URLComponents()
        parts.scheme = "folio-asset"; parts.host = "local"; parts.path = folder.isEmpty ? "/" : "/"+folder+"/"
        let newBase = parts.string ?? "folio-asset://local/"
        if lastDocument === doc, lastVersion == doc.contentVersion, base == newBase { return }
        markup = nil
        lastDocument = doc; lastVersion = doc.contentVersion
        base = newBase
        generation &+= 1
        let ticket = generation
        job?.cancel()
        renderer.cancelAllOperations()
        let work = DispatchWorkItem { [weak self, weak doc] in
            guard let self, let doc, self.generation == ticket else { return }
            let snapshot = doc.text
            self.renderer.addOperation { [weak self] in
                let html = renderMarkdown(snapshot)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == ticket else { return }
                    self.markup = html
                    self.paint()
                }
            }
        }
        job = work
        DispatchQueue.main.asyncAfter(deadline:.now()+0.075,execute:work)
    }
    deinit {
        job?.cancel()
        renderer.cancelAllOperations()
    }
    private func paint() {
        guard ready, let markup else { return }
        self.markup = nil
        web.callAsyncJavaScript("""
        const top=window.scrollY;
        document.body.style.fontSize = size + "px";
        document.querySelector('base').href=base;
        document.querySelector('main').innerHTML=markup;
        window.scrollTo(0,reset ? 0 : top);
        """,arguments:["size":15 * fontSize / Buffer.defaultFontSize,"markup":markup,"base":base,"reset":resetScroll],in:nil,in:.page,completionHandler:nil)
        resetScroll = false
    }
    func webView(_ webView: WKWebView,didFinish navigation: WKNavigation!) { ready = true; paint() }
    func webView(_ webView: WKWebView,decidePolicyFor action: WKNavigationAction,decisionHandler: @escaping (WKNavigationActionPolicy)->Void) {
        if action.navigationType == .linkActivated {
            if let u = action.request.url, ["http","https"].contains(u.scheme ?? "") { NSWorkspace.shared.open(u) }
            decisionHandler(.cancel)
        } else { decisionHandler(.allow) }
    }
}
