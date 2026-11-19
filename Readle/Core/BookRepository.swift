import Foundation

actor BookRepository {
    private let root: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Readle", isDirectory: true)
    }
    private nonisolated func directory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    nonisolated func coverURL(_ id: UUID) -> URL { directory(id).appendingPathComponent("cover.jpg") }
    func setCover(_ data: Data, for id: UUID) throws {
        guard FileManager.default.fileExists(atPath: directory(id).path) else { return }
        try data.write(to: coverURL(id), options: .atomic)
    }
    func list() throws -> [BookSummary] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
            .map { try decoder.decode(BookSummary.self, from: Data(contentsOf: $0.appendingPathComponent("summary.json"))) }
            .sorted { $0.addedAt > $1.addedAt }
    }
    func add(_ book: Book) throws -> BookSummary {
        let directory = directory(book.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let summary = BookSummary(book)
        do {
            try encoder.encode(book).write(to: directory.appendingPathComponent("content.json"), options: .atomic)
            try encoder.encode(summary).write(to: directory.appendingPathComponent("summary.json"), options: .atomic)
            try book.cover?.write(to: coverURL(book.id), options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        return summary
    }
    func load(_ id: UUID) throws -> Book {
        try decoder.decode(Book.self, from: Data(contentsOf: directory(id).appendingPathComponent("content.json")))
    }
    func reading(_ id: UUID) throws -> ReadingState {
        let file = directory(id).appendingPathComponent("reading.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return ReadingState() }
        return try decoder.decode(ReadingState.self, from: Data(contentsOf: file))
    }
    func save(_ state: ReadingState, for id: UUID) throws {
        guard FileManager.default.fileExists(atPath: directory(id).path) else { return }
        try encoder.encode(state).write(to: directory(id).appendingPathComponent("reading.json"), options: .atomic)
    }
    func delete(_ id: UUID) throws { try FileManager.default.removeItem(at: directory(id)) }
}
