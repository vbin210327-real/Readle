import Foundation
import NaturalLanguage

struct Sentence: Codable, Identifiable, Equatable, Sendable {
    let id: Int
    let text: String
    var isClause: Bool? = nil
}

struct Paragraph: Codable, Identifiable, Sendable {
    let id: Int
    let sentences: [Sentence]
    var text: String { sentences.map(\.text).joined() }
}

struct Chapter: Codable, Identifiable, Sendable {
    let id: Int
    let title: String
    let paragraphs: [Paragraph]
    var sentenceCount: Int { paragraphs.reduce(0) { $0 + $1.sentences.count } }
}

struct Book: Codable, Identifiable, Sendable {
    let id: UUID
    let title: String
    let author: String
    let format: String
    let chapters: [Chapter]
    /// The cover image from the original file, only while importing; saved beside the book, not in it.
    var cover: Data? = nil
    var sentenceCount: Int { chapters.reduce(0) { $0 + $1.sentenceCount } }
    private enum CodingKeys: String, CodingKey { case id, title, author, format, chapters }
}

struct BookSummary: Codable, Identifiable, Sendable {
    let id: UUID
    let title: String
    let author: String
    let format: String
    let chapterCount: Int
    let sentenceCount: Int
    let addedAt: Date
    init(_ book: Book) {
        id = book.id; title = book.title; author = book.author; format = book.format
        chapterCount = book.chapters.count; sentenceCount = book.sentenceCount; addedAt = Date()
    }
}

struct ReadingState: Codable, Sendable {
    var direction: TranslationDirection?
    var chapterIndex = 0
    var sentenceID: Int?
    var scrollPosition: ReadingPosition?
    var translations: [String: String] = [:]
}

struct ReadingPosition: Codable, Equatable, Sendable {
    var paragraphID: Int?
    var fraction: Double
    var sentenceID: Int?
}

enum TranslationDirection: String, Codable, CaseIterable, Identifiable {
    case toEnglish = "english", toChinese = "chinese"
    var id: String { rawValue }
    func cacheKey(chapter: Int, sentence: Int) -> String { "\(rawValue):\(chapter):\(sentence)" }
    /// No setting to choose: Chinese text goes to English, everything else to Chinese.
    static func detect(_ text: String) -> TranslationDirection {
        text.range(of: #"\p{Han}"#, options: .regularExpression) != nil ? .toEnglish : .toChinese
    }
}

enum BookError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

enum BookText {
    // Split only for presentation: original paragraph and first-sentence IDs
    // remain stable, so existing books and reading positions need no migration.
    static func readingClauses(_ book: Book) -> Book {
        let chapters = book.chapters.map { chapter in
            Chapter(id: chapter.id, title: chapter.title, paragraphs: chapter.paragraphs.map { paragraph in
                Paragraph(id: paragraph.id, sentences: paragraph.sentences.flatMap { sentence in
                    let characters = Array(sentence.text)
                    var pieces: [String] = []
                    var start = 0
                    for index in characters.indices where characters[index] == "," || characters[index] == "，" {
                        // Keep thousands separators and decimal-like numeric groups together.
                        if index > 0, index + 1 < characters.count,
                           characters[index - 1].isNumber, characters[index + 1].isNumber { continue }
                        pieces.append(String(characters[start...index]))
                        start = index + 1
                    }
                    if start < characters.count {
                        let tail = String(characters[start...])
                        if tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !pieces.isEmpty {
                            pieces[pieces.count - 1] += tail
                        } else { pieces.append(tail) }
                    }
                    guard pieces.count > 1 else { return [sentence] }
                    return pieces.enumerated().map { index, text in
                        // Cantor pairing yields a stable, distinct negative ID for each continuation.
                        let sum = sentence.id + index
                        let id = index == 0 ? sentence.id : -(sum * (sum + 1) / 2 + index + 1)
                        return Sentence(id: id, text: text, isClause: true)
                    }
                })
            })
        }
        return Book(id: book.id, title: book.title, author: book.author, format: book.format, chapters: chapters)
    }
    static func paragraphs(_ text: String) -> [Paragraph] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var nextSentence = 0
        return normalized.components(separatedBy: "\n").compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { return nil }
            let tokenizer = NLTokenizer(unit: .sentence)
            tokenizer.string = line
            if let language = NLLanguageRecognizer.dominantLanguage(for: line) { tokenizer.setLanguage(language) }
            var pieces: [String] = []
            tokenizer.enumerateTokens(in: line.startIndex..<line.endIndex) { range, _ in
                let text = String(line[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { pieces.append(text) }
                return true
            }
            if pieces.isEmpty { pieces = [line] }
            let sentences = pieces.enumerated().map { index, text in
                defer { nextSentence += 1 }
                // Preserve a readable space between Latin sentences, without adding spaces to Chinese prose.
                let suffix = index < pieces.count - 1 && text.last?.isASCII == true ? " " : ""
                return Sentence(id: nextSentence, text: text + suffix)
            }
            return Paragraph(id: sentences[0].id, sentences: sentences)
        }
    }

    static func chapters(_ parts: [(String, String)]) -> [Chapter] {
        var chapters: [Chapter] = []
        for (title, text) in parts {
            let paragraphs = paragraphs(text)
            guard !paragraphs.isEmpty else { continue }
            // Long plain-text books remain navigable without building thousands of views at once.
            for offset in stride(from: 0, to: paragraphs.count, by: 100) {
                let page = Array(paragraphs[offset..<min(offset + 100, paragraphs.count)])
                let label = paragraphs.count > 100 ? "\(title) · \(offset / 100 + 1)" : title
                chapters.append(Chapter(id: chapters.count, title: label, paragraphs: page))
            }
        }
        return chapters
    }

    static let sampleID = UUID(uuidString: "A561C5F0-12CF-4A9C-9D82-A6EC0DD9F201")!
    static var sample: Book {
        let text = """
        天刚亮，我推开窗，街道上还没有多少行人。昨夜的雨停了，树叶上留着细小的水珠。
        我决定去河边走一走。路过那家旧书店时，店主正在擦拭门口的木椅。
        “今天开门这么早？”我问。他笑了笑，说有一本书想留给我。
        那是一本很薄的旅行笔记。第一页只有一句话：有时候，最远的旅程，是重新看见身边的世界。
        我把书放进外套口袋，沿着河岸慢慢向前走。太阳从桥的另一侧升起来，水面变成了一条柔软的金色丝带。
        """
        return Book(id: sampleID, title: "清晨的旧书店", author: "句读院 · 阅读示例", format: "示例", chapters: chapters([("第一章 · 沿河而行", text)]))
    }
}
