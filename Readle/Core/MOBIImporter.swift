import Foundation

enum MOBIImporter {
    static func load(_ url: URL, fallbackTitle: String) throws -> Book {
        var status: Int32 = 0
        guard let source = url.withUnsafeFileSystemRepresentation({ path in readle_mobi_load(path, &status) }) else {
            switch status {
            case 5, 13: throw BookError.invalid("这本 MOBI 带有 DRM 加密，暂时无法读取。请使用未加密的 MOBI 或 EPUB。")
            case 100: throw BookError.invalid("这本 MOBI 文字或章节过多，请拆分后导入。")
            default: throw BookError.invalid("MOBI 正文无法解析，文件可能损坏或格式不受支持。请重新下载，或使用 EPUB 版本。")
            }
        }
        defer { readle_mobi_free(source) }
        func string(_ pointer: UnsafeMutablePointer<CChar>?) -> String {
            pointer.map { String(cString: $0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        }
        var parts: [(String, String)] = []
        var length = 0
        for index in 0..<source.pointee.count {
            let part = source.pointee.parts[index]
            let text = string(part.text).components(separatedBy: .newlines)
                .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
                .filter { !$0.isEmpty }.joined(separator: "\n")
            length += text.count
            guard length <= 5_000_000 else { throw BookError.invalid("这本书文字过多，请拆分后导入。") }
            if !text.isEmpty {
                let heading = string(part.heading)
                parts.append((heading.isEmpty ? (index == 0 ? "正文" : "章节 \(index + 1)") : heading, text))
            }
        }
        let title = string(source.pointee.title)
        var book = Book(id: UUID(), title: title.isEmpty ? fallbackTitle : title, author: string(source.pointee.author), format: "MOBI", chapters: BookText.chapters(parts))
        if let bytes = source.pointee.cover, source.pointee.coverSize > 0 {
            book.cover = BookCoverImage.thumbnail(Data(bytes: bytes, count: source.pointee.coverSize))
        }
        return book
    }
}
