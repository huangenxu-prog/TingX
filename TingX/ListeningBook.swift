import Foundation

enum ListeningBook {
    case epub(URL, [EPUBResource])
    case text([(title: String, body: String)])

    static func open(_ url: URL) throws -> Self {
        if url.pathExtension.lowercased() == "epub" {
            return .epub(url, try BookDocumentLoader.epubIndex(url).resources)
        }
        let text = try BookDocumentLoader.plainText(url)
        let heading = try NSRegularExpression(pattern: #"(?m)^[ \t　]*第[零〇一二两三四五六七八九十百千万0-9０-９]+[章节回卷部][^\n]{0,60}$"#)
        let ns = text as NSString
        let matches = heading.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var starts = matches.map { ($0.range.location, ns.substring(with: $0.range)) }
        if starts.first?.0 != 0 { starts.insert((0, "正文"), at: 0) }
        let chapters = starts.indices.compactMap { index -> (String, String)? in
            let (start, title) = starts[index]
            let end = index + 1 < starts.count ? starts[index + 1].0 : ns.length
            let body = ns.substring(with: NSRange(location: start, length: end - start))
            return body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : (title, body)
        }
        return .text(chapters)
    }

    var titles: [String] {
        switch self {
        case .epub(_, let resources):
            return resources.enumerated().map { index, item in
                if let title = item.title, !title.isEmpty { return title }
                return "第\(index + 1)节"
            }
        case .text(let chapters): return chapters.map { $0.title }
        }
    }

    func segments(at index: Int) throws -> [String] {
        let body: String
        switch self {
        case .epub(let url, let resources):
            body = try BookDocumentLoader.epubChapter(url, resource: resources[index])
        case .text(let chapters): body = chapters[index].body
        }
        var segments: [String] = []
        var buffer = ""
        var count = 0
        for character in body {
            buffer.append(character)
            count += 1
            if count == 32 || "。！？!?；;\n".contains(character) {
                try Task.checkCancellation()
                let piece = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !piece.isEmpty { segments.append(piece) }
                buffer = ""
                count = 0
            }
        }
        let last = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !last.isEmpty { segments.append(last) }
        return segments
    }
}
