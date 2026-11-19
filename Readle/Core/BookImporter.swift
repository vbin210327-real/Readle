import Foundation
import PDFKit
import ImageIO
import CoreGraphics
#if canImport(FoundationXML)
import FoundationXML
#endif

enum BookImporter {
    static func load(_ url: URL) throws -> Book {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard (values.fileSize ?? 0) <= 50_000_000 else { throw BookError.invalid("请选择 50 MB 以内的电子书。") }
        let ext = url.pathExtension.lowercased()
        let fallbackTitle = url.deletingPathExtension().lastPathComponent
        let book: Book
        switch ext {
        case "txt":
            let data = try Data(contentsOf: url)
            let text = try decodeText(data)
            guard text.count <= 5_000_000 else { throw BookError.invalid("这本书文字过多，请拆分后导入。") }
            book = Book(id: UUID(), title: fallbackTitle, author: "", format: "TXT", chapters: BookText.chapters([("正文", text)]))
        case "pdf":
            guard let document = PDFDocument(url: url), !document.isLocked else { throw BookError.invalid("PDF 无法读取或需要密码。") }
            guard document.pageCount <= 3000 else { throw BookError.invalid("PDF 页数过多，请拆分后导入。") }
            var parts: [(String, String)] = []
            var length = 0
            for index in 0..<document.pageCount {
                let text = document.page(at: index)?.string ?? ""
                length += text.count
                guard length <= 5_000_000 else { throw BookError.invalid("PDF 文字过多，请拆分后导入。") }
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // PDF wraps lines for layout. Merge them into paragraphs to avoid splitting sentences at every line.
                    let cleaned = text.components(separatedBy: "\n\n").map {
                        $0.replacingOccurrences(of: "-\n", with: "").replacingOccurrences(of: "\n", with: " ")
                    }.joined(separator: "\n")
                    parts.append(("第 \(index + 1) 页", cleaned))
                }
            }
            let title = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
            let author = document.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String ?? ""
            var pdf = Book(id: UUID(), title: title.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackTitle, author: author, format: "PDF", chapters: BookText.chapters(parts))
            pdf.cover = document.page(at: 0)?.pageRef.flatMap(BookCoverImage.render)
            book = pdf
        case "epub": book = try loadEPUB(Data(contentsOf: url), fallbackTitle: fallbackTitle)
        case "mobi": book = try MOBIImporter.load(url, fallbackTitle: fallbackTitle)
        default: throw BookError.invalid("请选择 EPUB、MOBI、TXT 或文字型 PDF 文件。")
        }
        guard !book.chapters.isEmpty else { throw BookError.invalid(ext == "pdf" ? "这份 PDF 没有可提取的文字。扫描版 PDF 暂不支持。" : "这本书中没有可读取的正文。") }
        return book
    }

    static func decodeText(_ data: Data) throws -> String {
        if data.starts(with: [0xFF, 0xFE]), let text = String(data: data, encoding: .utf16LittleEndian) { return text.replacingOccurrences(of: "\u{FEFF}", with: "") }
        if data.starts(with: [0xFE, 0xFF]), let text = String(data: data, encoding: .utf16BigEndian) { return text.replacingOccurrences(of: "\u{FEFF}", with: "") }
        if let text = String(data: data, encoding: .utf8) { return text.replacingOccurrences(of: "\u{FEFF}", with: "") }
        let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        if let text = String(data: data, encoding: gb) { return text }
        throw BookError.invalid("TXT 编码无法识别，请保存为 UTF-8 后导入。")
    }

    private static func loadEPUB(_ data: Data, fallbackTitle: String) throws -> Book {
        let archive = try ZIPArchive(data: data)
        let container = EPUBMetadata()
        try container.parse(archive.read("META-INF/container.xml"))
        guard let path = container.packagePath, !path.isEmpty else { throw BookError.invalid("EPUB 缺少书籍目录。") }
        let metadata = EPUBMetadata()
        try metadata.parse(archive.read(path))
        guard !metadata.spine.isEmpty else { throw BookError.invalid("EPUB 缺少阅读顺序。") }
        var parts: [(String, String)] = []
        var length = 0
        for id in metadata.spine {
            guard let item = metadata.items[id], item.mediaType.contains("html") else { continue }
            let member = try resolve(item.href, relativeTo: path)
            let text = try XHTMLText.extract(archive.read(member))
            length += text.body.count
            guard length <= 5_000_000 else { throw BookError.invalid("这本书文字过多，请拆分后导入。") }
            if !text.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append((text.heading.isEmpty ? "章节 \(parts.count + 1)" : text.heading, text.body))
            }
        }
        var book = Book(id: UUID(), title: metadata.title.isEmpty ? fallbackTitle : metadata.title, author: metadata.author, format: "EPUB", chapters: BookText.chapters(parts))
        if let id = metadata.coverID, let item = metadata.items[id], let member = try? resolve(item.href, relativeTo: path),
           let data = try? archive.read(member) {
            book.cover = BookCoverImage.thumbnail(data)
        }
        return book
    }

    private static func resolve(_ href: String, relativeTo package: String) throws -> String {
        let base = URL(string: "https://epub.invalid/")!.appendingPathComponent(package)
        guard let url = URL(string: href, relativeTo: base)?.absoluteURL.standardized,
              url.host == "epub.invalid", url.scheme == "https" else { throw BookError.invalid("EPUB 章节路径无效。") }
        return String(url.path.dropFirst())
    }
}

private final class EPUBMetadata: NSObject, XMLParserDelegate {
    struct Item { let href: String; let mediaType: String; let properties: String }
    var packagePath: String?
    var title = ""
    var author = ""
    var items: [String: Item] = [:]
    var spine: [String] = []
    private var coverMeta: String?
    /// EPUB 3 marks the cover item; EPUB 2 names it in <meta name="cover">; else an image called "cover".
    var coverID: String? {
        if let id = items.first(where: { $0.value.properties.split(separator: " ").contains("cover-image") })?.key { return id }
        if let id = coverMeta, items[id] != nil { return id }
        if let id = coverMeta, let match = items.first(where: { $0.value.href == id })?.key { return match }
        return items.filter { $0.value.mediaType.hasPrefix("image/") && ($0.key + $0.value.href).lowercased().contains("cover") }
            .map(\.key).sorted().first
    }
    private var capture: String?
    private var buffer = ""
    func parse(_ data: Data) throws {
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = self
        guard parser.parse() else { throw BookError.invalid("EPUB 目录 XML 无法解析。") }
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        let local = name.components(separatedBy: ":").last ?? name
        switch local {
        case "rootfile": if packagePath == nil { packagePath = attributes["full-path"] }
        case "title", "creator": capture = local; buffer = ""
        case "item": if let id = attributes["id"], let href = attributes["href"] { items[id] = Item(href: href, mediaType: attributes["media-type"] ?? "", properties: attributes["properties"] ?? "") }
        case "meta": if attributes["name"] == "cover", let content = attributes["content"] { coverMeta = content }
        case "itemref": if attributes["linear"] != "no", let id = attributes["idref"] { spine.append(id) }
        default: break
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if capture != nil { buffer += string } }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let local = name.components(separatedBy: ":").last ?? name
        if local == capture {
            let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if local == "title", title.isEmpty { title = value }
            if local == "creator", author.isEmpty { author = value }
            capture = nil
        }
    }
}

private final class XHTMLText: NSObject, XMLParserDelegate {
    private var lines: [String] = []
    private var buffer = ""
    private var inBody = false
    private var skipDepth = 0
    private var heading = ""
    private var headingTag: String?
    private var headingBuffer = ""
    private let blocks: Set<String> = ["p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "li", "blockquote", "section", "article", "tr"]

    static func extract(_ data: Data) throws -> (heading: String, body: String) {
        let delegate = XHTMLText()
        // HTML named entities are legal in EPUB XHTML, but XMLParser does not load an external DTD.
        var source = try BookImporter.decodeText(data)
        let entities = ["&nbsp;": "&#160;", "&mdash;": "&#8212;", "&ndash;": "&#8211;", "&hellip;": "&#8230;", "&ldquo;": "&#8220;", "&rdquo;": "&#8221;", "&lsquo;": "&#8216;", "&rsquo;": "&#8217;", "&copy;": "&#169;"]
        for (entity, replacement) in entities { source = source.replacingOccurrences(of: entity, with: replacement) }
        let parser = XMLParser(data: Data(source.utf8))
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else { throw BookError.invalid("EPUB 正文格式无法解析，请使用标准 EPUB 文件。") }
        delegate.flush()
        return (delegate.heading, delegate.lines.joined(separator: "\n"))
    }
    private func flush() {
        let clean = buffer.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if !clean.isEmpty { lines.append(clean) }
        buffer = ""
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        let tag = name.components(separatedBy: ":").last ?? name
        if skipDepth > 0 { skipDepth += 1; return }
        if ["script", "style", "nav", "svg"].contains(tag) { skipDepth = 1; return }
        if tag == "body" { inBody = true }
        guard inBody else { return }
        if blocks.contains(tag) || tag == "br" { flush() }
        if heading.isEmpty && ["h1", "h2", "h3"].contains(tag) { headingTag = tag; headingBuffer = "" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inBody, skipDepth == 0 else { return }
        buffer += string
        if headingTag != nil { headingBuffer += string }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if skipDepth > 0 { skipDepth -= 1; return }
        let tag = name.components(separatedBy: ":").last ?? name
        guard inBody else { return }
        if headingTag == tag { heading = headingBuffer.trimmingCharacters(in: .whitespacesAndNewlines); headingTag = nil }
        if blocks.contains(tag) { flush() }
        if tag == "body" { flush(); inBody = false }
    }
}

/// Small JPEG covers for the shelf, made with ImageIO so they work on any Apple platform.
enum BookCoverImage {
    static let maxPixel = 360

    static func thumbnail(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel] as CFDictionary) else { return nil }
        return jpeg(image)
    }

    /// The first page of a PDF, drawn on white.
    static func render(_ page: CGPDFPage) -> Data? {
        let box = page.getBoxRect(.cropBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let scale = CGFloat(maxPixel) / max(box.width, box.height)
        let width = Int(box.width * scale), height = Int(box.height * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.minX, y: -box.minY)
        context.drawPDFPage(page)
        return context.makeImage().flatMap(jpeg)
    }

    private static func jpeg(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}
