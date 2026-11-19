import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

struct LibraryView: View {
    @ObservedObject var store: LibraryStore
    @State private var showImporter = false
    @State private var pendingDelete: BookSummary?
    @State private var path: [UUID] = []
    @State private var showSearch = false
    @State private var showAccount = false
    /// The book being entered through the title (文字穿越), until it is on screen.
    @State private var entering: UUID?
    @StateObject private var entrance = BookEntrance()
    /// The reader of the book being entered, set up out of sight while the opened book holds still
    /// so the dive's letters open straight onto it; it hands over to the real reader afterwards.
    @State private var preview: UUID?
    @State private var previewShown = false
    @State private var previewBaseline = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var membership: Membership
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var shelfScene: ShelfScene?
    @State private var bookOpen = false
    @Environment(\.roomy) private var roomy
    /// The 3D view's size now (edge to edge), and the size its scene was set up at (see `ShelfScene.resume`).
    @State private var shelfSize: CGSize = .zero
    @State private var sceneSize: CGSize = .zero
    @State private var resizeTask: Task<Void, Never>?
    private let formats: [UTType] = [UTType(filenameExtension: "mobi") ?? UTType(importedAs: "com.amazon.mobi"), .plainText, .pdf, UTType(filenameExtension: "epub") ?? UTType(importedAs: "org.idpf.epub-container")]

    var body: some View {
        ZStack {
        NavigationStack(path: $path) {
            Group {
                if membership.allows(.shelf3D), let shelfScene, !store.books.isEmpty {
                    Shelf3DView(scene: shelfScene, books: shelfBooks, coverVersion: store.coverVersion,
                                onOpen: { id, page in enter(id, page: page) },
                                onMenu: { id in pendingDelete = store.books.first { $0.id == id } },
                                onResize: { shelfResized($0) },
                                resizing: sceneSize != .zero && shelfSize != sceneSize && path.isEmpty)
                        .id(ObjectIdentifier(shelfScene))
                        .transition(.opacity)
                        .onReceive(shelfScene.$bookOpen) { open in
                            bookOpen = open
                            if !open { shelfResized(shelfSize) } // a resize that waited for the book to close
                        }
                        .onAppear {
                            shelfScene.pageContent = { id in prepare(id); return await readingPage(id) }
                            shelfScene.prepareReader = { id in await buildReader(id) }
                            // Wake the speech engine early, off the main thread, so the reader starts quickly.
                            Task.detached(priority: .utility) { _ = AVSpeechSynthesizer() }
                        }
                } else if !membership.allows(.shelf3D) {
                    CatalogShelf(books: store.books, repository: store.repository, coverVersion: store.coverVersion,
                                 showEmptyState: store.libraryLoaded && !store.importing && store.error == nil,
                                 on3DShelf: membership.expiredPlan != nil ? { _ = membership.require(.shelf3D) } : nil,
                                 onImport: { showImporter = true },
                                 onSearch: { showSearch = true },
                                 onOpen: { book in Task { await store.open(book) } },
                                 onDelete: { pendingDelete = $0 })
                } else {
                    Palette.paper.ignoresSafeArea()
                }
            }
            .background(Palette.paper)
            .sheet(isPresented: $showAccount) {
                AccountView(membership: membership, bookCount: store.books.count)
            }
            .sheet(isPresented: $showSearch) {
                ShelfSearch(books: store.books, repository: store.repository, coverVersion: store.coverVersion) { book in
                    showSearch = false
                    if let shelfScene, let index = shelfBooks.firstIndex(where: { $0.id == book.id }) { shelfScene.jump(to: index) } else { Task { await store.open(book) } }
                } onDelete: { book in
                    pendingDelete = book
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .overlay {
                if membership.allows(.shelf3D) && store.libraryLoaded && store.books.isEmpty && !store.importing && store.error == nil {
                    ContentUnavailableView {
                        Label("书架还是空的", systemImage: "books.vertical")
                    } description: {
                        Text("从“文件”导入 EPUB、MOBI、TXT 或文字型 PDF，也可以在其他 App 中分享给句读院。")
                    } actions: {
                        Button { showImporter = true } label: { Text("导入电子书").foregroundStyle(Palette.paper) }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                if membership.allows(.shelf3D) { header } else { catalogHeader }
            }
            .navigationDestination(for: UUID.self) { id in
                if let book = store.openedBook, book.id == id {
                    ReaderView(book: book, repository: store.repository, startsWithControlsHidden: entering == id)
                        .environment(\.closeBook, {
                            // After a rotation or resize the open book's still no longer fits the
                            // screen, so the reader just slides away instead of flying back out.
                            guard membership.allows(.shelf3D), let shelfScene, shelfSize == sceneSize else { path = []; return }
                            entrance.leave(reduceMotion: reduceMotion) { path = [] } back: { start, duration in
                                shelfScene.returnFromDive(start: start, duration: duration)
                            }
                        })
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: formats) { result in
                switch result {
                case .success(let url): Task { await store.importBook(url) }
                case .failure(let error): store.error = error.localizedDescription
                }
            }
            // Books opened from the shelf go in through their title; new imports just slide in.
            .onChange(of: store.openedBook?.id) { _, id in if let id, id != entering { path = [id] } }
            .onChange(of: path) { _, path in
                if path.isEmpty { store.openedBook = nil; entering = nil; shelfScene?.settle(); shelfResized(shelfSize) }
            }
            .alert("无法完成操作", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
                Button("知道了", role: .cancel) { store.error = nil }
            } message: { Text(store.error ?? "") }
            .confirmationDialog("删除“\(pendingDelete?.title ?? "")”？原文件不受影响。", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
                Button("删除书籍、译文和听书音频", role: .destructive) {
                    if let book = pendingDelete { Task { await store.delete(book) } }
                    pendingDelete = nil
                }
                Button("取消", role: .cancel) { pendingDelete = nil }
            }
            .overlay {
                // Opening is near-instant and shows its own zoom, so only importing gets a cover sheet.
                if store.importing || !store.libraryLoaded {
                    ZStack {
                        Palette.paper.opacity(0.8).ignoresSafeArea()
                        VStack(spacing: 12) {
                            ProgressView()
                            Text(store.importing ? (store.importingTitle.map { "正在导入《\($0)》…" } ?? "正在整理书页…") : "正在打开书架…")
                                .font(.subheadline).foregroundStyle(Palette.muted)
                                .multilineTextAlignment(.center).padding(.horizontal, 32)
                        }
                    }
                }
            }
        }
        if membership.allows(.shelf3D), let id = preview, let book = store.openedBook, book.id == id {
            ReaderView(book: book, repository: store.repository, startsWithControlsHidden: true)
                .opacity(previewShown ? 1 : 0)
                .environment(\.readerOnScreen, previewShown)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        if membership.allows(.shelf3D) { EntranceOverlay(entrance: entrance) }
        // Off the shelf (in a book), an import from another app still says what is coming in.
        VStack {
            if let title = store.importingTitle, !path.isEmpty {
                ImportBanner(title: title)
                    .padding(.top, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer()
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: store.importingTitle)
        .allowsHitTesting(false)
        }
        .keyCommands(libraryCommands)
        // A book arriving from another app: put away 我的 or search so it can be seen.
        .onChange(of: store.importingTitle) { _, title in
            if title != nil { showAccount = false; showSearch = false }
        }
        .onChange(of: membership.allows(.shelf3D), initial: true) { _, pro in
            if pro { if shelfScene == nil { shelfScene = ShelfScene() } }
            else {
                shelfScene?.pageContent = nil; shelfScene?.prepareReader = nil
                entrance.reset()
                shelfScene = nil; bookOpen = false; entering = nil; preview = nil
            }
        }
    }

    /// Hardware keyboard on the shelf: ⌘F search, ⌘O import; on the 3D shelf the arrow keys turn
    /// the tower and Return opens the book in front. Only while the shelf itself is showing.
    private var libraryCommands: [KeyCommand] {
        let onShelf = path.isEmpty && entering == nil && !showSearch && !showAccount && !showImporter
            && pendingDelete == nil && !store.importing && store.libraryLoaded && !membership.showPaywall
        var commands = [
            KeyCommand(title: "搜索书籍", key: "f", enabled: onShelf && !store.books.isEmpty) { showSearch = true },
            KeyCommand(title: "导入电子书", key: "o", enabled: onShelf) { showImporter = true },
            KeyCommand(title: "我的", key: ",", enabled: onShelf) { showAccount = true },
        ]
        if let shelfScene, membership.allows(.shelf3D), !store.books.isEmpty {
            let turning = onShelf && !bookOpen
            commands += [
                KeyCommand(title: "下一本", key: .rightArrow, modifiers: [], enabled: turning) { shelfScene.turn(by: 1) },
                KeyCommand(title: "上一本", key: .leftArrow, modifiers: [], enabled: turning) { shelfScene.turn(by: -1) },
                KeyCommand(title: "打开书籍", key: .return, modifiers: [], enabled: turning) { shelfScene.openFocused() },
            ]
        }
        return commands
    }

    /// The 3D shelf changed size (rotation, Split View, Stage Manager): once it settles, and once
    /// you're back on the shelf, set the scene up again at the new size on the same book.
    private func shelfResized(_ size: CGSize) {
        shelfSize = size
        guard size.width > 0, size.height > 0 else { return }
        guard sceneSize != .zero else { sceneSize = size; return }
        resizeTask?.cancel()
        guard size != sceneSize else { return }
        resizeTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let old = shelfScene, membership.allows(.shelf3D),
                  path.isEmpty, entering == nil, !bookOpen, preview == nil, !entrance.visible else { return }
            let scene = ShelfScene(size: shelfSize)
            scene.resume(at: shelfBooks.indices.contains(old.focus) ? shelfBooks[old.focus].id : nil)
            old.pageContent = nil; old.prepareReader = nil; old.onOpen = nil; old.onMenu = nil
            entrance.reset()
            var instant = Transaction(); instant.disablesAnimations = true
            withTransaction(instant) { shelfScene = scene; sceneSize = shelfSize }
        }
    }

    /// While the opened book holds still: set up its reader out of sight and wait until it has drawn.
    private func buildReader(_ id: UUID) async {
        for _ in 0..<100 where store.openedBook?.id != id { try? await Task.sleep(for: .milliseconds(30)) }
        guard store.openedBook?.id == id, !reduceMotion else { return }
        previewBaseline = entrance.draws
        previewShown = false
        preview = id
        // Its one heavy frame happens now, while the scene is still; it finishes loading on its own
        // (well before the dive reaches the word) while the camera already eases in.
        try? await Task.sleep(for: .milliseconds(20))
        try? await Task.sleep(for: .milliseconds(20))
    }

    /// Entering a book from the shelf: its cover has just swung open; dive through the printed title.
    private func enter(_ id: UUID, page: OpenedPage) {
        guard store.books.contains(where: { $0.id == id }) else { return }
        if entering != id { prepare(id) }
        var instant = Transaction(); instant.disablesAnimations = true
        entrance.enter(page: page, reduceMotion: reduceMotion) {
            if preview == id {
                // Already set up behind the scene: once its page is drawn, let it show behind the still.
                await entrance.waitForReader(after: previewBaseline, timeout: 1.5)
                withTransaction(instant) { previewShown = true }
                try? await Task.sleep(for: .milliseconds(20))
                return
            }
            // Not set up in time: wait (briefly) for the book, then open the reader itself.
            for _ in 0..<100 where store.openedBook?.id != id { try? await Task.sleep(for: .milliseconds(30)) }
            guard store.openedBook?.id == id else { return }
            let drawn = entrance.draws
            withTransaction(instant) { path = [id] }
            await entrance.waitForReader(after: drawn, timeout: 1.5)
        } arrived: {
            // Hand over from the stand-in to the real reader (identical, so nothing visibly changes).
            guard preview == id else { return }
            let drawn = entrance.draws
            withTransaction(instant) { path = [id] }
            Task {
                await entrance.waitForReader(after: drawn, timeout: 2)
                withTransaction(instant) { preview = nil; previewShown = false }
            }
        }
    }

    /// A book has just been tapped on the shelf: start loading it now, while its cover opens and the
    /// camera closes in, so the reader is ready behind the word by the time you dive through.
    private func prepare(_ id: UUID) {
        guard let book = store.books.first(where: { $0.id == id }) else { return }
        entering = id
        if store.openedBook?.id != id { Task { await store.open(book) } }
    }

    /// The page you stopped at in a book (from its saved reading position), for the inside of
    /// the opened book on the shelf.
    private func readingPage(_ id: UUID) async -> InsidePage? {
        guard let stored = try? await store.repository.load(id) else { return nil }
        let state = (try? await store.repository.reading(id)) ?? ReadingState()
        // Off the main thread: splitting a long book takes a while, and the book is opening meanwhile.
        return await Task.detached(priority: .userInitiated) { Self.insidePage(stored, state: state) }.value
    }

    nonisolated private static func insidePage(_ stored: Book, state: ReadingState) -> InsidePage? {
        let book = BookText.readingClauses(stored)
        guard book.chapters.indices.contains(state.chapterIndex) else { return nil }
        let chapter = book.chapters[state.chapterIndex]
        let paragraphs = chapter.paragraphs
        guard !paragraphs.isEmpty else { return nil }
        // Where you are: the paragraph at the top of your screen and how far into it, or the
        // sentence you were on. Roughly is enough.
        let position = state.scrollPosition
        let anchor = paragraphs.firstIndex { $0.id == position?.paragraphID }
            ?? paragraphs.firstIndex { $0.sentences.contains { $0.id == state.sentenceID } } ?? 0
        let sentences = paragraphs[anchor].sentences
        var within = 0
        if let id = position?.sentenceID ?? (position == nil ? state.sentenceID : nil),
           let k = sentences.firstIndex(where: { $0.id == id }) {
            within = sentences[..<k].reduce(0) { $0 + $1.text.utf16.count }
        } else if let fraction = position?.fraction {
            within = Int(Double(paragraphs[anchor].text.utf16.count) * min(max(fraction, 0), 1))
        }
        // The surrounding text, then a printed page cut from it so your place sits about a third
        // of the way down, the page starting mid-paragraph if that's where it falls.
        let first = max(0, anchor - 8)
        var full = "", anchorStart = 0
        for k in first..<paragraphs.count {
            if !full.isEmpty { full += "\n" }
            if k == anchor { anchorStart = (full as NSString).length }
            full += paragraphs[k].text.trimmingCharacters(in: .whitespacesAndNewlines)
            if k > anchor && (full as NSString).length > anchorStart + within + 3600 { break }
        }
        let ns = full as NSString
        guard ns.length > 0 else { return nil }
        let target = min(anchorStart + within, ns.length - 1)
        var start = max(0, target - (BookPage.isCJK(full) ? 330 : 550))
        if start > 0 {
            let space = ns.rangeOfCharacter(from: .whitespacesAndNewlines, options: [],
                                            range: NSRange(location: start, length: min(40, ns.length - start)))
            if space.location != NSNotFound { start = space.location + 1 }
        }
        let continues = start > 0 && ns.character(at: start - 1) != 10 // not right after a line break
        let text = ns.substring(with: NSRange(location: start, length: min(ns.length - start, 3200)))
        let before = book.chapters[..<state.chapterIndex].reduce(0) { sum, chapter in
            sum + chapter.paragraphs.reduce(0) { $0 + $1.text.count }
        } + paragraphs[..<first].reduce(0) { $0 + $1.text.count } + start
        return InsidePage(heading: chapter.title, text: text, word: BookPage.chooseWord(in: text, near: target - start),
                          offset: before, continues: continues)
    }

    private var shelfBooks: [ShelfBook] {
        #if DEBUG
        // Test-only: -ReadleManyBooks fills the shelf with 3,000 copies to try a huge library.
        if ProcessInfo.processInfo.arguments.contains("-ReadleManyBooks"), let sample = store.books.first {
            return (0..<3000).map { i in
                let book = store.books[i % store.books.count]
                return ShelfBook(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", i)) ?? sample.id, title: "\(book.title) \(i + 1)", author: book.author,
                                 sentences: book.sentenceCount, coverURL: store.repository.coverURL(book.id))
            }
        }
        #endif
        return store.books.map { book in
            ShelfBook(id: book.id, title: book.title, author: book.author,
                      sentences: book.sentenceCount, coverURL: store.repository.coverURL(book.id))
        }
    }

    /// The 3D shelf fills the screen as a room; the header floats over its wall.
    private var inRoom: Bool { membership.allows(.shelf3D) && !store.books.isEmpty }
    private var nightRoom: Bool { inRoom && colorScheme == .dark }

    private var roomInk: Color { nightRoom ? .white : Palette.ink }

    private var catalogHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                catalogTitle.fixedSize()
                Spacer(minLength: 8)
                accountButton
            }
            VStack(alignment: .leading, spacing: 4) {
                catalogTitle
                accountButton.frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, CatalogShelf.gutter(roomy))
        .padding(.vertical, roomy ? 12 : 8)
        .frame(maxWidth: CatalogShelf.measure(roomy))
        .frame(maxWidth: .infinity)
        .background(CatalogShelf.paper.ignoresSafeArea(edges: .top))
        .overlay(alignment: .bottom) { Divider() }
    }

    private var catalogTitle: some View {
        Text("句读院")
            .font(.system(.largeTitle, design: .serif))
            .accessibilityAddTraits(.isHeader)
    }

    /// Opens 我的: your photo, membership, reading stats, settings and about.
    private var accountButton: some View {
        Button { showAccount = true } label: {
            AvatarView(size: 48)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
        .accessibilityLabel(membership.isPro ? "我的，高级版" : "我的")
        .accessibilityIdentifier("membership")
    }

    private var header: some View {
        Group {
            // A short screen (iPhone in landscape): one row, so the shelf keeps the height.
            if verticalSizeClass == .compact { compactHeader } else { tallHeader }
        }
        .background(inRoom ? Color.clear : Palette.paper)
        // Out of the way while a book is open, so the dive starts from the book alone.
        .opacity(bookOpen ? 0 : 1)
        .animation(.easeOut(duration: 0.25), value: bookOpen)
    }

    private var compactHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("句读院").font(.title2.bold()).foregroundStyle(roomInk)
                .shadow(color: .black.opacity(nightRoom ? 0.3 : 0), radius: 8, y: 1)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            accountButton
            ShelfToolbarButton(kind: .add, action: { showImporter = true })
            if !store.books.isEmpty {
                ShelfToolbarButton(kind: .search, action: { showSearch = true })
            }
        }
        .foregroundStyle(roomInk)
        .padding(.horizontal, 20).padding(.top, 6).padding(.bottom, 4)
    }

    private var tallHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: 10) {
                Text("句读院").font(.largeTitle.bold()).foregroundStyle(roomInk)
                    .shadow(color: .black.opacity(nightRoom ? 0.3 : 0), radius: 8, y: 1)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                accountButton
            }
            if !store.books.isEmpty {
                HStack(spacing: 10) {
                    Text("书架").font(.headline)
                        .shadow(color: .black.opacity(nightRoom ? 0.3 : 0), radius: 6, y: 1)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    ShelfToolbarButton(kind: .add, action: { showImporter = true })
                    ShelfToolbarButton(kind: .search, action: { showSearch = true })
                }
                .foregroundStyle(roomInk)
            }
        }
        .padding(.horizontal, roomy ? 32 : 20).padding(.top, roomy ? 14 : 8).padding(.bottom, 6)
    }

}

private struct ShelfToolbarButton: View {
    enum Kind { case add, search }
    let kind: Kind
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: kind == .add ? "plus" : "magnifyingglass")
                .font(.system(size: kind == .add ? 20 : 16, weight: kind == .add ? .semibold : .medium))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .hoverEffect(.highlight)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(kind == .add ? "导入电子书" : "搜索书籍")
        .accessibilityIdentifier(kind == .add ? "importBook" : "searchBooks")
    }
}

private struct CatalogShelf: View {
    static let paper = Color(UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(red: 0.083, green: 0.078, blue: 0.072, alpha: 1)
        }
        return UIColor(red: 0.973, green: 0.965, blue: 0.948, alpha: 1)
    })
    let books: [BookSummary]
    let repository: BookRepository
    let coverVersion: Int
    let showEmptyState: Bool
    let on3DShelf: (() -> Void)?
    let onImport: () -> Void
    let onSearch: () -> Void
    let onOpen: (BookSummary) -> Void
    let onDelete: (BookSummary) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.roomy) private var roomy

    /// Side margins and the widest the shelf grows: wider on iPad, where the covers are larger too.
    static func gutter(_ roomy: Bool) -> CGFloat { roomy ? 40 : 24 }
    static func measure(_ roomy: Bool) -> CGFloat { roomy ? 1180 : 960 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                catalogIndex
                if showEmptyState && books.isEmpty {
                    emptyShelf
                } else if books.count == 1, let book = books.first, !typeSize.isAccessibilitySize {
                    bookLink(book) {
                        HStack(alignment: .center, spacing: roomy ? 36 : 24) {
                            cover(book).frame(maxWidth: roomy ? 260 : 184)
                            caption(book, featured: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxWidth: roomy ? 680 : 520, alignment: .leading)
                    }
                } else {
                    let minimum: CGFloat = typeSize.isAccessibilitySize ? 232 : roomy ? 172 : 144
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum, maximum: roomy ? 232 : 244), spacing: roomy ? 28 : 20, alignment: .topLeading)],
                              alignment: .leading, spacing: roomy ? 40 : 32) {
                        ForEach(books) { book in
                            bookLink(book) {
                                VStack(alignment: .leading, spacing: 8) {
                                    cover(book)
                                    caption(book, featured: false)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Self.gutter(roomy))
            .padding(.top, roomy ? 20 : 12)
            .padding(.bottom, 32)
            .frame(maxWidth: Self.measure(roomy))
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Self.paper.ignoresSafeArea())
        .accessibilityIdentifier("flatShelf")
    }

    private var catalogIndex: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("书架")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 4)
            if let on3DShelf, !books.isEmpty {
                Button(action: on3DShelf) {
                    Label("3D 书架", systemImage: "lock")
                        .font(.footnote)
                        .foregroundStyle(Palette.muted)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("locked3DShelf")
            }
            ShelfToolbarButton(kind: .add, action: onImport)
            if !books.isEmpty {
                ShelfToolbarButton(kind: .search, action: onSearch)
            }
        }
    }

    private var emptyShelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("书架还是空的")
                .font(.system(.title2, design: .serif))
            Text("支持 EPUB、MOBI、TXT 和文字型 PDF")
                .font(.subheadline)
                .foregroundStyle(Palette.muted)
            Button(action: onImport) {
                Text("导入电子书")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Self.paper)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 44)
                    .background(Palette.accent, in: RoundedRectangle(cornerRadius: 8))
                    .hoverEffect(.lift)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 24)
    }

    private func bookLink<Content: View>(_ book: BookSummary, @ViewBuilder content: () -> Content) -> some View {
        Button { onOpen(book) } label: {
            content().frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(book.title)
        .accessibilityValue(book.author)
        .contextMenu { Button("删除", systemImage: "trash", role: .destructive) { onDelete(book) } }
    }

    private func cover(_ book: BookSummary) -> some View {
        CatalogCover(book: book, url: repository.coverURL(book.id), version: coverVersion)
            .hoverEffect(.lift)
            .accessibilityHidden(true)
    }

    private func caption(_ book: BookSummary, featured: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(book.title)
                .font(.system(featured ? .title2 : .subheadline, design: .serif).weight(.medium))
                .lineLimit(featured || typeSize.isAccessibilitySize ? nil : 2)
            if !book.author.isEmpty {
                Text(book.author)
                    .font(featured ? .subheadline : .caption)
                    .foregroundStyle(Palette.muted)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
            }
        }
        .multilineTextAlignment(.leading)
    }
}

private struct CatalogCover: View {
    private static let cloth = [
        Color(red: 0.25, green: 0.32, blue: 0.28),
        Color(red: 0.35, green: 0.23, blue: 0.24),
        Color(red: 0.23, green: 0.28, blue: 0.34),
        Color(red: 0.35, green: 0.29, blue: 0.22)
    ]
    let book: BookSummary
    let url: URL
    let version: Int
    @State private var image: UIImage?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.roomy) private var roomy

    var body: some View {
        Color.clear.aspectRatio(0.72, contentMode: .fit)
            .overlay(alignment: .bottomLeading) {
                Group {
                    if let image {
                        Image(uiImage: image).resizable().scaledToFit()
                    } else {
                        typesetJacket
                    }
                }
                .clipShape(.rect(topLeadingRadius: 2, bottomLeadingRadius: 2, bottomTrailingRadius: 5, topTrailingRadius: 5))
                .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.16), radius: 5, y: 3)
            }
            .task(id: "\(url.path)#\(version)") {
                let loaded = await Task.detached(priority: .utility) { [url] in UIImage(contentsOfFile: url.path) }.value
                if !Task.isCancelled { image = loaded }
            }
    }

    private var typesetJacket: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(book.title)
                .font(.system(size: roomy ? 23 : 20, weight: .medium, design: .serif))
                .lineLimit(4)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 8)
            if !book.author.isEmpty {
                Text(book.author)
                    .font(.system(size: roomy ? 12.5 : 11))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(2)
            }
        }
        .multilineTextAlignment(.leading)
        .foregroundStyle(Color(red: 0.98, green: 0.95, blue: 0.89))
        .padding(.leading, 20)
        .padding(.trailing, 12)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Self.cloth[Int(book.id.uuid.0) % Self.cloth.count])
        .overlay(alignment: .leading) {
            Rectangle().fill(.black.opacity(0.16)).frame(width: 7)
                .overlay(alignment: .trailing) { Rectangle().fill(.white.opacity(0.12)).frame(width: 1) }
        }
    }
}

/// Find a book by title or author; picking one spins the shelf to it.
private struct ShelfSearch: View {
    let books: [BookSummary]
    let repository: BookRepository
    let coverVersion: Int
    let onPick: (BookSummary) -> Void
    let onDelete: (BookSummary) -> Void
    @State private var query = ""
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    private var results: [BookSummary] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return books }
        return books.filter { $0.title.localizedCaseInsensitiveContains(text) || $0.author.localizedCaseInsensitiveContains(text) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
                TextField("书名或作者", text: $query)
                    .focused($focused)
                    .submitLabel(.search)
                    .onSubmit { if let first = results.first { onPick(first) } }
                    .accessibilityIdentifier("searchField")
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.muted) }
                        .accessibilityLabel("清除")
                }
            }
            .padding(.horizontal, 14).frame(height: 44)
            .background(Palette.accent.opacity(0.07), in: Capsule())
            .safeAreaInset(edge: .trailing, spacing: 12) {
                // iPad's centered sheet has no grabber to swipe down; give it a way out.
                if Device.isPad {
                    Button("取消") { dismiss() }
                        .tint(Palette.ink)
                        .frame(minHeight: 44)
                        .hoverEffect(.highlight)
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("searchCancel")
                }
            }
            .padding(.horizontal, 20).padding(.top, 22).padding(.bottom, 8)

            if results.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List(results) { book in
                    Button { onPick(book) } label: {
                        HStack(spacing: 14) {
                            BookCover(url: repository.coverURL(book.id), letter: book.title.first.map(String.init) ?? "", version: coverVersion)
                                .scaleEffect(0.75).frame(width: 39, height: 54)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(book.title).font(.system(.body, design: .serif).weight(.medium)).foregroundStyle(Palette.ink).lineLimit(2)
                                if !book.author.isEmpty {
                                    Text(book.author).font(.subheadline).foregroundStyle(Palette.muted).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .hoverEffect(.highlight)
                    .accessibilityIdentifier("searchResult-" + book.id.uuidString)
                    .listRowBackground(Color.clear)
                    .swipeActions { Button("删除", systemImage: "trash", role: .destructive) { onDelete(book) } }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .onAppear { focused = true }
    }
}

/// The book's own cover when it has one; otherwise its first letter on a quiet tile.
private struct BookCover: View {
    let url: URL
    let letter: String
    let version: Int
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Text(letter).font(.system(.title, design: .serif)).foregroundStyle(Palette.accent)
            }
        }
        .frame(width: 52, height: 72)
        .background(Palette.accent.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay { if image != nil { RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.black.opacity(0.08), lineWidth: 0.5) } }
        .shadow(color: .black.opacity(image == nil ? 0 : 0.12), radius: 3, y: 1.5)
        .task(id: "\(url.path)#\(version)") {
            let url = url
            image = await Task.detached(priority: .utility) { UIImage(contentsOfFile: url.path) }.value
        }
    }
}

/// "正在导入《书名》…" floating over the reader while a book comes in from another app.
private struct ImportBanner: View {
    let title: String
    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("正在导入《\(title)》…")
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
        .padding(.horizontal, 24)
        .accessibilityElement(children: .combine)
    }
}
