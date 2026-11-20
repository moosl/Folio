import Foundation
import CYaml

struct FrontMatter {
    let html: String
    let body: String

    private static let block = try! NSRegularExpression(
        pattern: #"(?m)\A\uFEFF?---[ \t]*\r?\n([\s\S]*?)^(?:---|\.\.\.)[ \t]*(?:\r?\n|\z)"#
    )

    init?(_ text: String) {
        guard text.hasPrefix("---") || text.hasPrefix("\u{FEFF}---") else { return nil }
        let ns = text as NSString
        guard let match = Self.block.firstMatch(in:text,range:NSRange(location:0,length:ns.length)) else { return nil }
        let yaml = ns.substring(with:match.range(at:1))
        var parser = yaml_parser_t()
        guard yaml_parser_initialize(&parser) != 0 else { return nil }
        defer { yaml_parser_delete(&parser) }
        var document = yaml_document_t()
        let parsed = Array(yaml.utf8CString).withUnsafeBytes { bytes -> Bool in
            yaml_parser_set_input_string(&parser,bytes.bindMemory(to:UInt8.self).baseAddress,bytes.count-1)
            return yaml_parser_load(&parser,&document) != 0
        }
        guard parsed else { return nil }
        defer { yaml_document_delete(&document) }
        guard let root = yaml_document_get_root_node(&document), root.pointee.type == YAML_MAPPING_NODE else { return nil }

        func display(_ node: yaml_node_t) -> String {
            if node.type == YAML_SCALAR_NODE {
                let scalar = node.data.scalar
                return String(decoding:UnsafeBufferPointer(start:scalar.value,count:scalar.length),as:UTF8.self)
            }
            // Keep nested collections in their original YAML notation.
            let source = yaml.unicodeScalars
            let start = source.index(source.startIndex,offsetBy:node.start_mark.index)
            let end = source.index(start,offsetBy:node.end_mark.index-node.start_mark.index)
            return String(source[start..<end]).trimmingCharacters(in:.whitespacesAndNewlines)
        }
        func escaped(_ text:String) -> String {
            text.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"<",with:"&lt;").replacingOccurrences(of:">",with:"&gt;")
        }
        let pairs = root.pointee.data.mapping.pairs
        var fields = [String:[String]]()
        for pair in UnsafeBufferPointer(start:pairs.start,count:pairs.top-pairs.start) {
            guard let key = yaml_document_get_node(&document,pair.key),
                  let value = yaml_document_get_node(&document,pair.value) else { return nil }
            let name = display(key.pointee).lowercased()
            if value.pointee.type == YAML_SEQUENCE_NODE {
                let items = value.pointee.data.sequence.items
                fields[name] = UnsafeBufferPointer(start:items.start,count:items.top-items.start).compactMap { item in
                    yaml_document_get_node(&document,item).map { display($0.pointee) }
                }
            } else { fields[name] = [display(value.pointee)] }
        }
        var parts = [String]()
        if let title = fields["title"]?.first, !title.isEmpty {
            parts.append("<h1>\(escaped(title))</h1>")
        }
        let metadata = ["author","date","topic","language"].flatMap { fields[$0] ?? [] }.filter { !$0.isEmpty }
        if !metadata.isEmpty {
            parts.append("<p class=\"byline\">"+metadata.map(escaped).joined(separator:" · ")+"</p>")
        }
        if let summary = (fields["summary"] ?? fields["description"])?.first, !summary.isEmpty {
            parts.append("<p class=\"summary\">\(escaped(summary))</p>")
        }
        if let tags = fields["tags"], !tags.isEmpty {
            parts.append("<p class=\"tags\">"+tags.map { "<span>\(escaped($0))</span>" }.joined()+"</p>")
        }
        html = parts.isEmpty ? "" : "<header class=\"frontmatter\">"+parts.joined()+"</header>"
        body = ns.substring(from:NSMaxRange(match.range))
    }
}
