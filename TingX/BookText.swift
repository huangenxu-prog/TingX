import Foundation
import CoreFoundation
import ZIPFoundation
enum BookReadError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

struct EPUBResource: Codable, Sendable { let path: String; var title: String? = nil }
struct EPUBResourceIndex: Codable, Sendable {
    let title: String
    let author: String
    let resources: [EPUBResource]
}

/// Reads EPUB entries in memory; archive paths are never written to disk.
enum BookDocumentLoader {
    static func plainText(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        guard data.count <= 50 * 1024 * 1024 else {
            throw BookReadError.invalid("文件过大，请导入小于 50 MB 的 TXT。")
        }
        let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        // Only try UTF-16 when a BOM exists; arbitrary GB bytes can otherwise decode as gibberish.
        let bytes = Array(data.prefix(3))
        let encodings: [String.Encoding] = bytes.starts(with: [0xff, 0xfe]) || bytes.starts(with: [0xfe, 0xff])
            ? [.utf16] : [.utf8, gb]
        guard let text = encodings.lazy.compactMap({ String(data: data, encoding: $0) }).first,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BookReadError.invalid("正文为空或无法识别文字编码。")
        }
        return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    private static let normalizationRules: [(NSRegularExpression, String)] = [
        (#"[\x{00A0}\x{2002}\x{2003}\x{3000}\t]+"#, " "),
        (#" *\n *"#, "\n"),
        (#"\n{3,}"#, "\n\n")
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    private static func normalizeReadingText(_ source: String) -> String {
        var text = source.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.replacingOccurrences(of: "\r", with: "\n")
        for (expression, replacement) in normalizationRules {
            text = expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replacement)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Read only EPUB package metadata and its spine. No chapter XHTML is decompressed.
    /// This is the first stage of resource-oriented, on-demand EPUB loading.
    static func epubIndex(_ url: URL) throws -> EPUBResourceIndex {
        let archive = try Archive(url: url, accessMode: .read)
        func extract(_ path: String) throws -> Data {
            guard let entry = archive[path], entry.type == .file,
                  entry.uncompressedSize <= 4 * 1024 * 1024 else {
                throw BookReadError.invalid("EPUB 目录文件缺失或过大。")
            }
            var data = Data()
            _ = try archive.extract(entry) { try Task.checkCancellation(); data.append($0) }
            return data
        }
        let container = EPUBXML()
        try container.parse(extract("META-INF/container.xml"))
        guard let package = container.packagePath else {
            throw BookReadError.invalid("EPUB 未包含有效的书籍目录。")
        }
        let opf = EPUBXML()
        try opf.parse(extract(package))
        let base = URL(fileURLWithPath: "/" + package).deletingLastPathComponent()
        var names: [String: String] = [:]
        if let nav = opf.navigationPath ?? opf.items.values.first(where: { $0.type == "application/x-dtbncx+xml" })?.href {
            let navURL = base.appendingPathComponent(nav.removingPercentEncoding ?? nav).standardizedFileURL
            let navigator = EPUBXML()
            if let bytes = try? extract(String(navURL.path.dropFirst())), (try? navigator.parse(bytes)) != nil {
                for (href, title) in navigator.navigationTitles {
                    let relative = String(href.split(separator: "#", maxSplits: 1).first ?? "")
                    let path = navURL.deletingLastPathComponent().appendingPathComponent(relative.removingPercentEncoding ?? relative).standardizedFileURL.path
                    if names[String(path.dropFirst())] == nil { names[String(path.dropFirst())] = title }
                }
            }
        }
        let resources: [EPUBResource] = try opf.spine.compactMap { id in
            guard let item = opf.items[id] else {
                throw BookReadError.invalid("EPUB 阅读顺序引用了不存在的章节。")
            }
            guard item.type == "application/xhtml+xml" || item.type == "text/html" else { return nil }
            let href = String(item.href.split(separator: "#", maxSplits: 1).first ?? "")
            guard !href.contains("://"), !href.hasPrefix("/") else {
                throw BookReadError.invalid("EPUB 章节地址无效。")
            }
            let path = base.appendingPathComponent(href.removingPercentEncoding ?? href)
                .standardizedFileURL.path
            return EPUBResource(path: String(path.dropFirst()), title: names[String(path.dropFirst())])
        }
        guard !resources.isEmpty else { throw BookReadError.invalid("EPUB 没有可阅读的文字章节。") }
        return EPUBResourceIndex(title: opf.title.trimmingCharacters(in: .whitespacesAndNewlines),
                                 author: opf.author.trimmingCharacters(in: .whitespacesAndNewlines),
                                 resources: resources)
    }

    /// Extract a single spine resource without parsing the rest of the book.
    static func epubChapter(_ url: URL, resource: EPUBResource) throws -> String {
        let archive = try Archive(url: url, accessMode: .read)
        guard let entry = archive[resource.path], entry.type == .file,
              entry.uncompressedSize <= 16 * 1024 * 1024 else {
            throw BookReadError.invalid("EPUB 章节缺失或过大。")
        }
        var data = Data()
        _ = try archive.extract(entry) { try Task.checkCancellation(); data.append($0) }
        let chapter = EPUBXML()
        try chapter.parse(data, body: true)
        return normalizeReadingText(chapter.bodyText)
    }

}

private final class EPUBXML: NSObject, XMLParserDelegate {
    var packagePath: String?
    var items: [String: (href: String, type: String)] = [:]
    var spine: [String] = []
    var title = ""
    var author = ""
    var bodyText = ""
    var heading = ""
    var navigationPath: String?
    var navigationTitles: [(String, String)] = []
    private var navPoints: [(href: String, title: String)] = []
    private var anchorHref: String?
    private var anchorText = ""
    private var headingDepth = 0
    private var elements: [String] = []
    private var readingBody = false
    private var bodyOnly = false
    private var ignoredDepth = 0
    private var bodyFragments: [String] = []
    private var lastWasNewline = false

    func parse(_ data: Data, body: Bool = false) throws {
        try Task.checkCancellation()
        bodyOnly = body
        // EPUB XHTML often uses HTML entities from an external DTD. Resolve the
        // common typography locally, without fetching external resources.
        var xml = data
        if body, var text = String(data: data, encoding: .utf8), text.contains("&") {
            let entities = ["nbsp": 160, "ensp": 8194, "emsp": 8195, "thinsp": 8201,
                            "ndash": 8211, "mdash": 8212, "lsquo": 8216, "rsquo": 8217,
                            "ldquo": 8220, "rdquo": 8221, "hellip": 8230, "bull": 8226,
                            "middot": 183, "copy": 169, "reg": 174, "trade": 8482]
            for (name, code) in entities {
                text = text.replacingOccurrences(of: "&\(name);", with: "&#\(code);")
            }
            xml = Data(text.utf8)
        }
        let parser = XMLParser(data: xml)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = self
        let succeeded = parser.parse()
        try Task.checkCancellation()
        guard succeeded else {
            throw BookReadError.invalid("EPUB 目录或章节格式损坏，无法读取。")
        }
        if bodyOnly { bodyText = bodyFragments.joined() }
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if Task.isCancelled { parser.abortParsing(); return }
        elements.append(name)
        if !bodyOnly {
            if name == "item", attributes["properties"]?.split(separator: " ").contains("nav") == true { navigationPath = attributes["href"] }
            if name == "navPoint" { navPoints.append(("", "")) }
            if name == "content", let href = attributes["src"], !navPoints.isEmpty { navPoints[navPoints.count - 1].href = href }
            if name == "a" { anchorHref = attributes["href"]; anchorText = "" }
        }
        if name == "rootfile", packagePath == nil { packagePath = attributes["full-path"] }
        if name == "item", let id = attributes["id"], let href = attributes["href"] {
            items[id] = (href, attributes["media-type"] ?? "")
        }
        if name == "itemref", attributes["linear"] != "no", let id = attributes["idref"] { spine.append(id) }
        if name == "body" { readingBody = true }
        if bodyOnly && readingBody && heading.isEmpty && ["h1", "h2", "h3"].contains(name) { headingDepth = elements.count }
        if ignoredDepth > 0 || ["script", "style", "nav"].contains(name) { ignoredDepth += 1 }
        if bodyOnly && readingBody && ignoredDepth == 0 && ["p", "div", "br", "h1", "h2", "h3", "li"].contains(name) { newline() }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if Task.isCancelled { parser.abortParsing(); return }
        if !bodyOnly {
            if !navPoints.isEmpty && elements.contains("navLabel") { navPoints[navPoints.count - 1].title += string }
            if anchorHref != nil { anchorText += string }
        }
        if bodyOnly {
            if readingBody && ignoredDepth == 0 {
                if headingDepth > 0 && heading.count < 100 { heading += string }
                bodyFragments.append(string)
                lastWasNewline = string.hasSuffix("\n")
            }
        } else if elements.contains("metadata") {
            if elements.last == "title" { title += string }
            if elements.last == "creator" { author += string }
        }
    }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let text = String(data: CDATABlock, encoding: .utf8) { self.parser(parser, foundCharacters: text) }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if !bodyOnly {
            if name == "navPoint", let item = navPoints.popLast(), !item.href.isEmpty {
                navigationTitles.append((item.href, item.title.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            if name == "a", let href = anchorHref {
                navigationTitles.append((href, anchorText.trimmingCharacters(in: .whitespacesAndNewlines)))
                anchorHref = nil
            }
        }
        if bodyOnly && readingBody && ignoredDepth == 0 && ["p", "div", "h1", "h2", "h3", "li"].contains(name) { newline() }
        if ignoredDepth > 0 { ignoredDepth -= 1 }
        if headingDepth == elements.count { headingDepth = 0 }
        if name == "body" { readingBody = false }
        _ = elements.popLast()
    }
    private func newline() {
        if !lastWasNewline { bodyFragments.append("\n"); lastWasNewline = true }
    }
}
