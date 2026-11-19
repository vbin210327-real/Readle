import Foundation

enum ImportAllowance {
    static let limit = 100
    static func allows(count: Int, pro: Bool) -> Bool { pro || count < limit }
    static var shared: UserDefaults? { UserDefaults(suiteName: SharedImportInbox.groupID) }
    static let countKey = "imports.libraryCount"
    static let proThroughKey = "imports.proThrough"
    static let upgradeKey = "imports.requestedUpgrade"
}

struct SharedImportInbox: Sendable {
    static let groupID = "group.com.linfanbin.readle"
    struct Entry: Sendable {
        let id: UUID
        let directory: URL
        let file: URL
    }
    let root: URL
    private let checkSharedAllowance: Bool

    init(root: URL? = nil) throws {
        checkSharedAllowance = root == nil
        if let root { self.root = root }
        else {
            guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.groupID) else {
                throw ImportError.message("共享书架无法访问，请重新打开句读院后再试。")
            }
            self.root = container.appendingPathComponent("Imports", isDirectory: true)
        }
    }

    @discardableResult
    func enqueue(_ source: URL, name: String? = nil) throws -> Entry {
        guard source.isFileURL else { throw ImportError.message("请分享已下载的电子书文件，而不是网页链接。") }
        let filename = (name ?? source.lastPathComponent) as NSString
        let safeName = filename.lastPathComponent
        guard ["epub", "mobi", "txt", "pdf"].contains((safeName as NSString).pathExtension.lowercased()) else {
            throw ImportError.message("请选择 EPUB、MOBI、TXT 或 PDF 文件。")
        }
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let values = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= 50_000_000 else {
            throw ImportError.message("请选择非空、50 MB 以内的电子书文件。")
        }
        if checkSharedAllowance, let defaults = ImportAllowance.shared {
            let pro = (defaults.object(forKey: ImportAllowance.proThroughKey) as? Date ?? .distantPast) > Date()
            if !ImportAllowance.allows(count: defaults.integer(forKey: ImportAllowance.countKey), pro: pro) {
                defaults.set(true, forKey: ImportAllowance.upgradeKey)
                throw ImportError.message("普通版已达到 100 本导入上限。打开句读院可升级，或删除一本书后重新分享。")
            }
        }
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var rootURL = root
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try rootURL.setResourceValues(resourceValues)
        let id = UUID()
        let staging = root.appendingPathComponent(id.uuidString + ".pending", isDirectory: true)
        let committed = root.appendingPathComponent(id.uuidString + ".ready", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        try fm.copyItem(at: source, to: staging.appendingPathComponent(safeName))
        // A directory rename publishes the complete file to the reader in one step.
        try fm.moveItem(at: staging, to: committed)
        return Entry(id: id, directory: committed, file: committed.appendingPathComponent(safeName))
    }

    func entries() throws -> [Entry] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return [] }
        return try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey])
            .sorted { (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast < (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast }
            .compactMap { directory in
                guard directory.pathExtension == "ready", let id = UUID(uuidString: directory.deletingPathExtension().lastPathComponent) else { return nil }
                let files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                guard files.count == 1, let file = files.first else { throw ImportError.message("共享的电子书文件不完整。") }
                return Entry(id: id, directory: directory, file: file)
            }
    }

    func remove(_ entry: Entry) throws { try FileManager.default.removeItem(at: entry.directory) }
}

enum ImportError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
