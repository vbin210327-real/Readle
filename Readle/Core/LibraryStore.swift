import SwiftUI
import CryptoKit
import NaturalLanguage

// A word explanation includes its sentence-specific usage. Reuse it only when
// the complete context matches; the same spelling can have different senses.
private enum WordMeaningCache {
    private static let storageKey = "readle.wordMeaningCache.v1"
    private static let limit = 1000
    private struct Entry: Codable {
        let key: String
        let meaning: String
    }
    private static func key(word: String, context: String, direction: TranslationDirection) -> String {
        let components = [direction.rawValue, word, context].map {
            $0.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
        let encoded = (try? JSONEncoder().encode(components)) ?? Data()
        return SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
    }
    private static func entries() -> [Entry] {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }
    static func get(word: String, context: String, direction: TranslationDirection) -> String? {
        let lookup = key(word: word, context: context, direction: direction)
        return entries().last { $0.key == lookup }?.meaning
    }
    static func put(_ meaning: String, word: String, context: String, direction: TranslationDirection) {
        let lookup = key(word: word, context: context, direction: direction)
        var saved = entries().filter { $0.key != lookup }
        saved.append(Entry(key: lookup, meaning: meaning))
        if saved.count > limit { saved.removeFirst(saved.count - limit) }
        if let data = try? JSONEncoder().encode(saved) { UserDefaults.standard.set(data, forKey: storageKey) }
    }
}

@MainActor
final class LibraryStore: ObservableObject {
    @Published var books: [BookSummary] = [] {
        didSet { ImportAllowance.shared?.set(importedCount, forKey: ImportAllowance.countKey) }
    }
    private var importedCount: Int { books.filter { $0.id != BookText.sampleID }.count }
    @Published private(set) var libraryLoaded = false
    @Published var importing = false
    /// The book being imported right now (its file name without the extension), so the app can say
    /// which one wherever you are.
    @Published private(set) var importingTitle: String?
    @Published var opening = false
    @Published var error: String?
    @Published var openedBook: Book?
    /// Bumped when a cover is added to a book already on the shelf, so its tile reloads.
    @Published private(set) var coverVersion = 0
    let repository = BookRepository()
    private var startup: Task<Void, Never>?
    private var receiving = false

    func start() async {
        if let startup { await startup.value; return }
        let task = Task { await loadLibrary() }
        startup = task
        await task.value
    }

    private func loadLibrary() async {
        defer { libraryLoaded = true }
        do {
            books = try await repository.list()
            if !UserDefaults.standard.bool(forKey: "sampleAdded") {
                if !books.contains(where: { $0.id == BookText.sampleID }) {
                    let sample = try await repository.add(BookText.sample)
                    books.append(sample)
                }
                UserDefaults.standard.set(true, forKey: "sampleAdded")
            }
        } catch { self.error = "书架读取失败：\(error.localizedDescription)" }
    }

    func importBook(_ url: URL) async {
        await start()
        guard !importing else { return }
        importing = true
        importingTitle = url.deletingPathExtension().lastPathComponent
        do {
            let book = try await Task.detached(priority: .userInitiated) { try BookImporter.load(url) }.value
            try await addOrRefresh(book)
        } catch { self.error = error.localizedDescription }
        importing = false
        importingTitle = nil
        await receiveSharedBooks()
    }

    func activate() async {
        await start()
        if let shared = ImportAllowance.shared, shared.bool(forKey: ImportAllowance.upgradeKey) {
            shared.removeObject(forKey: ImportAllowance.upgradeKey)
            _ = Membership.shared.require(.importBook(currentCount: importedCount))
        }
        await receiveSharedBooks()
    }

    private func receiveSharedBooks() async {
        guard !receiving, !importing else { return }
        receiving = true; importing = true
        defer { receiving = false; importing = false; importingTitle = nil }
        do {
            let inbox = try SharedImportInbox()
            for entry in try inbox.entries() {
                importingTitle = entry.file.deletingPathExtension().lastPathComponent
                if books.contains(where: { $0.id == entry.id }) {
                    // A prior launch saved the book but was interrupted before removing its inbox file.
                    try inbox.remove(entry)
                    continue
                }
                let parsed: Book
                do {
                    parsed = try await Task.detached(priority: .userInitiated) { try BookImporter.load(entry.file) }.value
                } catch {
                    self.error = "\(entry.file.lastPathComponent)：\(error.localizedDescription)"
                    try inbox.remove(entry)
                    continue
                }
                var book = Book(id: entry.id, title: parsed.title, author: parsed.author, format: parsed.format, chapters: parsed.chapters)
                book.cover = parsed.cover
                guard try await addOrRefresh(book) else { break }
                // Keep the source until the library save succeeds; storage errors remain retryable.
                try inbox.remove(entry)
            }
        } catch { self.error = "分享导入失败：\(error.localizedDescription)" }
    }

    /// Importing a book that's already on the shelf gives it its cover and opens it, keeping your
    /// place and translations, instead of adding a second copy.
    @discardableResult private func addOrRefresh(_ book: Book) async throws -> Bool {
        if let existing = books.first(where: { $0.title == book.title && $0.author == book.author && $0.format == book.format && $0.sentenceCount == book.sentenceCount }) {
            if let cover = book.cover { try await repository.setCover(cover, for: existing.id); coverVersion += 1 }
            await open(existing)
            return true
        }
        guard Membership.shared.require(.importBook(currentCount: importedCount)) else { return false }
        let summary = try await repository.add(book)
        books.insert(summary, at: 0)
        openedBook = book
        return true
    }

    func open(_ summary: BookSummary) async {
        guard !opening else { return }
        opening = true
        defer { opening = false }
        do { openedBook = try await repository.load(summary.id) }
        catch { self.error = "书籍读取失败：\(error.localizedDescription)" }
    }

    func delete(_ summary: BookSummary) async {
        do {
            try await repository.delete(summary.id)
            BookAudioPreparer.shared.deleteAudio(for: summary.id)
            books.removeAll { $0.id == summary.id }
            await receiveSharedBooks()
        } catch { self.error = "删除失败：\(error.localizedDescription)" }
    }
}

@MainActor
final class ReaderStore: ObservableObject {
    let book: Book
    private let repository: BookRepository
    func tierChanged() {
        cancel(); dismissWord()
        translation = selected.flatMap { cachedTranslation(for: translationKey($0)) }
        error = nil
    }
    @Published private(set) var state = ReadingState()
    @Published private(set) var selected: Sentence?
    @Published private(set) var translation: String?
    @Published private(set) var translating = false
    @Published private(set) var error: String?
    @Published var storageError: String?
    @Published private(set) var loaded = false
    @Published private(set) var chapterChangeID = 0
    private var request: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var scrollSaveTask: Task<Void, Never>?
    private var requestID = UUID()
    @Published var word: String?
    @Published private(set) var wordMeaning: String?
    @Published private(set) var wordLoading = false
    @Published private(set) var wordError: String?
    private var wordTask: Task<Void, Never>?
    private var wordToken = UUID()
    private var wordSentence: Sentence?
    private var wordKey: String?

    init(book: Book, repository: BookRepository) { self.book = BookText.readingClauses(book); self.repository = repository }
    private func translationKey(_ sentence: Sentence) -> String {
        let key = TranslationDirection.detect(sentence.text).cacheKey(chapter: chapter.id, sentence: sentence.id)
        return sentence.isClause == true ? "clause:v1:\(key)" : key
    }
    private func cachedTranslation(for key: String) -> String? {
        state.translations[key] ?? state.translations["apple:" + key]
    }
    var chapter: Chapter { book.chapters[state.chapterIndex] }
    var selectedParagraph: Int? { chapter.paragraphs.first { $0.sentences.contains { $0.id == selected?.id } }?.id }
    var resumeParagraph: Int? { chapter.paragraphs.first { $0.sentences.contains { $0.id == state.sentenceID } }?.id }
    var progress: Double {
        let before = book.chapters.prefix(state.chapterIndex).reduce(0) { $0 + $1.sentenceCount }
        let sentences = chapter.paragraphs.flatMap(\.sentences)
        let visibleSentence: Int?
        if let position = state.scrollPosition { visibleSentence = position.sentenceID ?? position.paragraphID }
        else { visibleSentence = state.sentenceID }
        let within = visibleSentence.flatMap { id in sentences.firstIndex { $0.id == id } }.map { $0 + 1 } ?? 0
        return Double(before + within) / Double(max(book.sentenceCount, 1))
    }

    func load() async {
        guard !loaded else { return }
        do {
            state = try await repository.reading(book.id)
            state.chapterIndex = min(max(state.chapterIndex, 0), book.chapters.count - 1)
            if let id = state.sentenceID, let sentence = chapter.paragraphs.flatMap(\.sentences).first(where: { $0.id == id }) {
                selected = sentence
                translation = cachedTranslation(for: translationKey(sentence))
            }
        } catch { storageError = "阅读记录读取失败：\(error.localizedDescription)" }
        loaded = true
    }

    func changeChapter(_ index: Int) {
        guard book.chapters.indices.contains(index) else { return }
        cancel()
        dismissWord()
        scrollSaveTask?.cancel()
        state.chapterIndex = index
        state.sentenceID = nil
        state.scrollPosition = nil
        selected = nil; translation = nil; error = nil
        chapterChangeID += 1
        persist()
    }

    func recordPosition(_ position: ReadingPosition) {
        guard loaded, state.scrollPosition != position else { return }
        state.scrollPosition = position
        scrollSaveTask?.cancel()
        scrollSaveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            self?.persist()
        }
    }

    func flushPosition() {
        scrollSaveTask?.cancel()
        scrollSaveTask = nil
        if loaded { persist() }
    }

    /// Select a sentence for the listening actions without requesting a translation.
    func selectForListening(_ sentence: Sentence) {
        cancel()
        selected = sentence
        state.sentenceID = sentence.id
        translation = cachedTranslation(for: translationKey(sentence))
        error = nil
        persist()
    }

    func select(_ sentence: Sentence, retry: Bool = false) {
        if selected?.id == sentence.id && (translation != nil || translating) && !retry { return }
        cancel()
        selected = sentence
        state.sentenceID = sentence.id
        translation = nil; error = nil
        let key = translationKey(sentence)
        if !retry, let cached = cachedTranslation(for: key) {
            translation = cached
            persist()
            return
        }
        persist()
        translating = true
        let token = requestID
        let context = contextAround(sentence)
        request = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await Membership.shared.translate(sentence: sentence.text, context: context) { [weak self] partial in
                    guard let self, requestID == token, !Task.isCancelled else { return }
                    translation = partial
                }
                guard !Task.isCancelled, token == requestID else { return }
                translation = result
                state.translations[key] = result
                persist()
            } catch is CancellationError {
                // Selection changed or the reader closed.
            } catch {
                guard !Task.isCancelled, token == requestID else { return }
                translation = nil
                self.error = error.localizedDescription
            }
            if token == requestID { translating = false }
        }
    }

    private var cachedAnnotationChapter: Int?
    private var cachedAnnotationTranslations: [String: String] = [:]
    private var cachedAnnotations: [Int: [String: String]] = [:]

    /// Definitions already looked up in this chapter, keyed by sentence and word.
    var wordAnnotations: [Int: [String: String]] {
        if cachedAnnotationChapter == chapter.id, cachedAnnotationTranslations == state.translations {
            return cachedAnnotations
        }
        var result: [Int: [String: String]] = [:]
        for (key, meaning) in state.translations {
            if key.hasPrefix("apple:"), state.translations[String(key.dropFirst("apple:".count))] != nil { continue }
            let parts = key.components(separatedBy: ":")
            guard let marker = parts.firstIndex(of: "word"), parts.count > marker + 4,
                  let chapterID = Int(parts[marker + 2]), chapterID == chapter.id,
                  let sentenceID = Int(parts[marker + 3]) else { continue }
            let word = parts[(marker + 4)...].joined(separator: ":")
            let plain = meaning.replacingOccurrences(of: "**", with: "")
            let first = plain.components(separatedBy: CharacterSet(charactersIn: "\n。；;"))
                .first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !word.isEmpty, !first.isEmpty else { continue }
            let sentenceText = chapter.paragraphs.lazy.flatMap(\.sentences).first { $0.id == sentenceID }?.text ?? ""
            let hasPart = first.range(of: #"(?i)^\s*(n|v|adj|adv|pron|prep|conj|det|int)\."#, options: .regularExpression) != nil
            let part = hasPart ? "" : Self.partOfSpeech(word, in: sentenceText)
            result[sentenceID, default: [:]][word] = part + String(first.prefix(24))
        }
        cachedAnnotationChapter = chapter.id
        cachedAnnotationTranslations = state.translations
        cachedAnnotations = result
        return result
    }

    private static func partOfSpeech(_ word: String, in sentence: String) -> String {
        guard TranslationDirection.detect(word) == .toChinese,
              let range = sentence.range(of: word, options: [.caseInsensitive]) else { return "" }
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = sentence
        tagger.setLanguage(.english, range: sentence.startIndex..<sentence.endIndex)
        let tag = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lexicalClass).0
        switch tag {
        case .noun: return "n. "
        case .verb: return "v. "
        case .adjective: return "adj. "
        case .adverb: return "adv. "
        case .pronoun: return "pron. "
        case .preposition: return "prep. "
        case .conjunction: return "conj. "
        case .determiner: return "det. "
        case .interjection: return "int. "
        default: return ""
        }
    }

    func dismissWord() {
        wordTask?.cancel(); wordToken = UUID()
        wordKey = nil
        word = nil; wordMeaning = nil; wordError = nil; wordLoading = false
    }

    func retryWord() {
        if let word, let wordSentence { lookup(word, sentence: wordSentence) }
    }

    func lookup(_ value: String, sentence: Sentence) {
        let target = TranslationDirection.detect(value)
        let key = "\(sentence.isClause == true ? "clause:v1:" : "")word:\(target.rawValue):\(chapter.id):\(sentence.id):\(value)"
        // A repeated tap must neither restart a pending request nor reselect a
        // meaning that is already on screen. Failed requests can be retried.
        if wordKey == key && (wordLoading || wordMeaning != nil) { return }
        dismissWord()
        wordKey = key
        word = value
        wordSentence = sentence
        wordLoading = true
        let token = wordToken
        if let cached = state.translations[key] {
            WordMeaningCache.put(cached, word: value, context: sentence.text, direction: target)
            wordMeaning = cached; wordLoading = false; return
        }
        if let cached = WordMeaningCache.get(word: value, context: sentence.text, direction: target) {
            wordMeaning = cached; wordLoading = false
            state.translations[key] = cached; persist()
            return
        }
        if let cached = state.translations["apple:" + key] {
            wordMeaning = cached; wordLoading = false; return
        }
        wordTask = Task { [weak self] in
            guard let self else { return }
            do {
                // Coalesce rapid taps on different uncached words before
                // starting an AI request; cached meanings remain instant.
                try await Task.sleep(for: .milliseconds(500))
                try Task.checkCancellation()
                let result = try await Membership.shared.translate(sentence: value, context: sentence.text, word: true)
                guard !Task.isCancelled, wordToken == token else { return }
                wordMeaning = result; state.translations[key] = result
                WordMeaningCache.put(result, word: value, context: sentence.text, direction: target)
                persist()
            } catch TranslationAllowance.LimitError.exhausted {
                if wordToken == token { dismissWord() }
            } catch {
                guard !Task.isCancelled, wordToken == token else { return }
                wordError = error.localizedDescription
            }
            if wordToken == token { wordLoading = false }
        }
    }

    private func contextAround(_ sentence: Sentence) -> String {
        let sentences = chapter.paragraphs.flatMap(\.sentences)
        guard let index = sentences.firstIndex(where: { $0.id == sentence.id }) else { return "" }
        let neighbors = sentences[max(0, index - 2)..<index] + sentences[(index + 1)..<min(sentences.count, index + 3)]
        return neighbors.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n")
    }

    func cancel() {
        request?.cancel(); request = nil
        requestID = UUID()
        if translating { translation = nil }
        translating = false
    }

    private func persist() {
        let snapshot = state
        let prior = saveTask
        // Serial snapshots prevent an older save from overwriting a newer tap or translation.
        saveTask = Task { [repository, book] in
            await prior?.value
            do { try await repository.save(snapshot, for: book.id) }
            catch { self.storageError = "阅读记录保存失败：\(error.localizedDescription)" }
        }
    }
}
