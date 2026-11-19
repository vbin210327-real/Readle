import Foundation
import PDFKit
import AppKit

@main
struct CoreTests {
    static var checks = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try value() else { throw BookError.invalid("FAIL: \(label)") }
        checks += 1
    }
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let chinese = BookText.paragraphs("天刚亮，我推开窗。昨夜的雨停了！你要出门吗？\n我们沿着河岸走。")
        try check(chinese.count == 2, "paragraph boundaries")
        try check(chinese[0].sentences.count == 3, "Chinese punctuation sentence segmentation")
        try check(chinese.flatMap(\.sentences).map(\.id) == [0, 1, 2, 3], "stable unique sentence IDs")
        try check(BookText.paragraphs("Mr. Smith is here. He brought a book.")[0].sentences.count == 2, "abbreviation segmentation")

        let txt = try BookImporter.load(root.appendingPathComponent("sample.txt"))
        try check(txt.sentenceCount == 4 && txt.format == "TXT", "UTF-8 text import")
        let utf16 = try BookImporter.load(root.appendingPathComponent("utf16.txt"))
        try check(utf16.chapters[0].paragraphs[0].text == "中文内容。", "UTF-16 BOM import")
        let gb = try BookImporter.load(root.appendingPathComponent("gb.txt"))
        try check(gb.chapters[0].paragraphs[0].text == "中文内容。", "GB18030 text import")

        let epub = try BookImporter.load(root.appendingPathComponent("sample.epub"))
        try check(epub.title == "测试电子书" && epub.author == "测试作者", "EPUB metadata")
        try check(epub.chapters.map(\.title) == ["第一章", "第二章"], "EPUB spine order rather than manifest or filename order")
        try check(epub.chapters[0].paragraphs.map(\.text).joined().contains("昨夜的雨停了。"), "nested inline XHTML and deflated ZIP")
        try check(!epub.chapters[0].paragraphs.map(\.text).joined().contains("跳过的导航"), "navigation text excluded")
        try check(epub.chapters[1].paragraphs.map(\.text).joined().contains("“故事”"), "named HTML entity decoding and encoded member paths")
        do {
            _ = try BookImporter.load(root.appendingPathComponent("corrupt.epub"))
            throw BookError.invalid("FAIL: corrupted EPUB accepted")
        } catch let error as BookError {
            try check(!error.localizedDescription.hasPrefix("FAIL:"), "corrupt archive rejected")
        }
        let mobi = try BookImporter.load(root.appendingPathComponent("sample.mobi"))
        try check(mobi.title == "MOBI测试电子书" && mobi.author == "测试作者" && mobi.format == "MOBI", "MOBI metadata and UTF-8")
        let mobiText = mobi.chapters.flatMap(\.paragraphs).map(\.text).joined(separator: "\n")
        try check(mobiText.contains("我们沿着河岸慢慢向前走。雨已经停了。"), "PalmDOC decompression and inline Chinese markup")
        try check(mobiText.contains("“故事”继续了。") && mobiText.contains("明天再见。"), "legacy HTML recovery, entities and br boundaries")
        try check(!mobiText.contains("隐藏") && mobi.chapters[0].title == "第一章", "MOBI headings and hidden markup exclusion")
        let uncompressed = try BookImporter.load(root.appendingPathComponent("uncompressed.mobi"))
        try check(uncompressed.sentenceCount == mobi.sentenceCount, "uncompressed MOBI reading")
        let western = try BookImporter.load(root.appendingPathComponent("cp1252.mobi"))
        try check(western.title == "Café" && western.chapters[0].paragraphs[0].text.contains("Café & tea. It’s lovely."), "MOBI CP1252 conversion")
        for file in ["encrypted.mobi", "corrupt.mobi"] {
            do {
                _ = try BookImporter.load(root.appendingPathComponent(file))
                throw BookError.invalid("FAIL: invalid MOBI accepted")
            } catch let error as BookError {
                try check(!error.localizedDescription.hasPrefix("FAIL:"), "invalid MOBI rejected")
                if file == "encrypted.mobi" { try check(error.localizedDescription.contains("DRM"), "actionable encrypted MOBI error") }
            }
        }
        // Optional upstream samples exercise real HUFF/CDIC and KF8 files without keeping books in the repo.
        if let sampleArg = CommandLine.arguments.first(where: { $0.hasPrefix("--mobi-samples=") }) {
            let samples = URL(fileURLWithPath: String(sampleArg.dropFirst("--mobi-samples=".count)))
            for name in ["sample-cp1252.mobi", "sample-unicode-huffdic.mobi", "sample-unicode-uncompressed.mobi", "sample-ncx.mobi", "sample-obfuscated-fonts.mobi"] {
                let book = try BookImporter.load(samples.appendingPathComponent(name))
                try check(book.sentenceCount > (name == "sample-ncx.mobi" ? 0 : 20) && !book.title.isEmpty, "real upstream MOBI: \(name)")
                print("MOBI sample: \(name), \(book.sentenceCount) sentences, \(book.chapters.count) chapters")
            }
        }
        let long = BookText.chapters([("正文", Array(repeating: "这是一句话。", count: 205).joined(separator: "\n"))])
        try check(long.count == 3 && long.map(\.sentenceCount).reduce(0, +) == 205, "long chapters remain navigable without text loss")
        try check(Set(long.flatMap(\.paragraphs).flatMap(\.sentences).map(\.id)).count == 205, "split chapters keep unique sentence identifiers")

        // Generate a genuine selectable-text PDF, using the same OS PDF framework as the app.
        let pdfURL = root.appendingPathComponent("sample.pdf")
        let data = NSMutableData()
        var bounds = CGRect(x: 0, y: 0, width: 400, height: 500)
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        let context = CGContext(consumer: consumer, mediaBox: &bounds, nil)!
        context.beginPDFPage(nil)
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
        ("A morning by the river. The rain has stopped." as NSString).draw(at: CGPoint(x: 30, y: 400), withAttributes: [.font: NSFont.systemFont(ofSize: 14)])
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage(); context.closePDF()
        try (data as Data).write(to: pdfURL)
        let pdf = try BookImporter.load(pdfURL)
        try check(pdf.format == "PDF" && pdf.sentenceCount == 2, "real PDF selectable text import")
        let blankURL = root.appendingPathComponent("blank.pdf")
        let blankImage = NSImage(size: NSSize(width: 100, height: 100))
        blankImage.lockFocus(); NSColor.white.setFill(); NSBezierPath(rect: NSRect(x: 0, y: 0, width: 100, height: 100)).fill(); blankImage.unlockFocus()
        let blank = PDFDocument(); blank.insert(PDFPage(image: blankImage)!, at: 0); blank.write(to: blankURL)
        do {
            _ = try BookImporter.load(blankURL)
            throw BookError.invalid("FAIL: empty image PDF accepted")
        } catch let error as BookError { try check(!error.localizedDescription.hasPrefix("FAIL:"), "image PDF clearly rejected") }

        let inbox = try SharedImportInbox(root: root.appendingPathComponent("inbox"))
        let queued = try inbox.enqueue(root.appendingPathComponent("sample.txt"), name: "分享的书.txt")
        let queuedFiles = try inbox.entries()
        try check(queuedFiles.count == 1 && queuedFiles[0].id == queued.id, "share inbox commits a stable import identity")
        try check(try Data(contentsOf: queued.file) == Data(contentsOf: root.appendingPathComponent("sample.txt")), "share retains complete file contents")
        let staging = inbox.root.appendingPathComponent(UUID().uuidString + ".pending")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try check(try inbox.entries().count == 1, "reader ignores unfinished share writes")
        let sharedBook = try BookImporter.load(queued.file)
        try check(sharedBook.title == "分享的书" && sharedBook.sentenceCount == 4, "shared filename and text import")
        for source in [URL(string: "https://example.com/book.txt")!, root.appendingPathComponent("sample.epub")] {
            do {
                _ = try inbox.enqueue(source, name: "unsupported.jpg")
                throw BookError.invalid("FAIL: invalid share accepted")
            } catch is ImportError { checks += 1 }
        }
        try inbox.remove(queued)
        try check(try inbox.entries().isEmpty && FileManager.default.fileExists(atPath: root.appendingPathComponent("sample.txt").path), "inbox cleanup preserves original download")
        let queuedMOBI = try inbox.enqueue(root.appendingPathComponent("sample.mobi"), name: "分享.MOBI")
        try check(try BookImporter.load(queuedMOBI.file).sentenceCount == mobi.sentenceCount, "shared uppercase MOBI filename and actual body import")
        try inbox.remove(queuedMOBI)

        let repository = BookRepository(root: root.appendingPathComponent("library"))
        _ = try await repository.add(epub)
        let books = try await repository.list()
        try check(books.count == 1 && books[0].title == epub.title, "library persistence")
        let loaded = try await repository.load(epub.id)
        try check(loaded.sentenceCount == epub.sentenceCount, "book reload")
        var state = ReadingState()
        state.chapterIndex = 1; state.sentenceID = 2; state.translations["english:1:2"] = "The story."
        state.scrollPosition = ReadingPosition(paragraphID: 1, fraction: 0.43, sentenceID: 1)
        try await repository.save(state, for: epub.id)
        let saved = try await repository.reading(epub.id)
        try check(saved.chapterIndex == 1 && saved.sentenceID == 2 && saved.translations["english:1:2"] == "The story.", "reading position and translation cache reload")
        try check(saved.scrollPosition == state.scrollPosition, "intra-paragraph scroll position survives repository reload independently of translation selection")
        let legacy = try JSONDecoder().decode(ReadingState.self, from: Data(#"{"chapterIndex":1,"sentenceID":2,"translations":{"english:1:2":"The story."}}"#.utf8))
        try check(legacy.scrollPosition == nil && legacy.chapterIndex == 1 && legacy.translations["english:1:2"] == "The story.", "old reading records migrate without losing chapter or cached translations")
        try await repository.delete(epub.id)
        let afterDelete = try await repository.list()
        try check(afterDelete.isEmpty, "book removal includes cache")

        var received: [String] = []
        let translator = TranslationService { prompt, progress in
            try check(prompt.system.contains("专业文学翻译官"), "sentence keeps the contextual translation prompt")
            try check(prompt.user.contains("<context>今天出门。雨停了。</context>")
                && prompt.user.contains("into 英文") && prompt.user.hasSuffix("<source>雨停了。</source>"), "Chinese sentence routes to English with context and selection separated")
            await progress?("The rain")
            await progress?("The rain has stopped.")
            return "  The rain has stopped.\n"
        }
        let translation = try await translator.translate(sentence: "  雨停了。  ", context: "今天出门。雨停了。") { received.append($0) }
        try check(translation == "The rain has stopped." && received == ["The rain", translation], "translation streams cumulative text and returns the trimmed result")
        let dictionary = TranslationService { prompt, _ in
            try check(prompt.system.contains("阅读词典") && prompt.system.contains("不翻译整个句子"), "word lookup keeps its distinct prompt")
            try check(prompt.user.contains("Raindrops covered the leaves.") && prompt.user.hasSuffix("输出语言：简体中文"), "English word uses its sentence context and routes to simplified Chinese")
            return "n. 雨滴"
        }
        let meaning = try await dictionary.translate(sentence: "Raindrops", context: "Raindrops covered the leaves.", word: true)
        try check(meaning == "n. 雨滴", "contextual lookup returns the model output")
        try check(TranslationDirection.detect("𠮷") == .toEnglish, "supplementary Han characters route to English")
        try check(legacy.direction == nil, "legacy records retain default direction")
        state.direction = .toChinese
        let directionState = try JSONDecoder().decode(ReadingState.self, from: JSONEncoder().encode(state))
        try check(directionState.direction == .toChinese && directionState.translations["english:1:2"] == "The story.", "direction persists without losing existing cache")
        let emptyTranslator = TranslationService { _, _ in "  " }
        do {
            _ = try await emptyTranslator.translate(sentence: "雨停了。", context: "")
            throw BookError.invalid("FAIL: empty translation accepted")
        } catch let error as BookError {
            try check(!error.localizedDescription.hasPrefix("FAIL:"), "empty model output is rejected")
        }
        let (started, signal) = AsyncStream<Void>.makeStream()
        let slowTranslator = TranslationService { _, _ in
            signal.yield()
            signal.finish()
            try await Task.sleep(for: .seconds(30))
            return "The rain has stopped."
        }
        let pending = Task { try await slowTranslator.translate(sentence: "雨停了。", context: "") }
        var starts = started.makeAsyncIterator()
        _ = await starts.next()
        pending.cancel()
        do {
            _ = try await pending.value
            throw BookError.invalid("FAIL: cancelled translation completed")
        } catch is CancellationError {
            try check(true, "translation propagates cancellation")
        }
        try check(ImportAllowance.allows(count: 99, pro: false), "free member can add the hundredth import")
        try check(!ImportAllowance.allows(count: 100, pro: false), "free member cannot add the 101st import")
        try check(!ImportAllowance.allows(count: 130, pro: false) && ImportAllowance.allows(count: 130, pro: true), "lapse blocks additional imports and renewal restores access")
        try await checkTranslationAllowance()
        print("PASS: \(checks) checks")
    }

    @MainActor
    private static func checkTranslationAllowance() async throws {
        let suite = "readle.translation.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let allowance = TranslationAllowance(defaults: defaults)
        for _ in 1..<100 {
            _ = try await allowance.perform(isPro: false) { "译文" }
        }
        try check(TranslationAllowance(defaults: UserDefaults(suiteName: suite)!).remaining == 1,
                  "free usage persists across quota reloads")

        do {
            _ = try await allowance.perform(isPro: false) { throw BookError.invalid("模型无法加载") }
            throw BookError.invalid("FAIL: generation error swallowed")
        } catch {
            try check(error.localizedDescription == "模型无法加载" && allowance.remaining == 1,
                      "a generation failure leaves the last use available")
        }

        let (started, signal) = AsyncStream<Void>.makeStream()
        let pending = Task {
            try await allowance.perform(isPro: false) {
                signal.yield()
                signal.finish()
                try await Task.sleep(for: .seconds(30))
                return "译文"
            }
        }
        var starts = started.makeAsyncIterator()
        _ = await starts.next()
        defer { pending.cancel() }
        do {
            _ = try await allowance.perform(isPro: false) { throw BookError.invalid("FAIL: overbooked free translations") }
            throw BookError.invalid("FAIL: concurrent request accepted")
        } catch TranslationAllowance.LimitError.inProgress {
            try check(allowance.remaining == 1, "an in-flight request reserves the final use")
        }
        pending.cancel()
        do {
            _ = try await pending.value
            throw BookError.invalid("FAIL: cancelled translation completed")
        } catch is CancellationError {
            try check(allowance.remaining == 1, "cancellation releases the reserved use")
        }

        let last = try await allowance.perform(isPro: false) { "n. 雨滴" }
        try check(last == "n. 雨滴" && allowance.remaining == 0, "the 100th successful translation or lookup is allowed")
        do {
            _ = try await allowance.perform(isPro: false) { throw BookError.invalid("FAIL: generated after free quota ran out") }
            throw BookError.invalid("FAIL: 101st free use accepted")
        } catch TranslationAllowance.LimitError.exhausted {
            try check(true, "the 101st request is blocked before model inference")
        }
        let paid = try await allowance.perform(isPro: true) { "译文" }
        try check(paid == "译文" && allowance.remaining == 0, "paid generation works without resetting the free balance")
    }
}
