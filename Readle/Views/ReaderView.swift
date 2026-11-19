import SwiftUI
import NaturalLanguage

struct ReaderView: View {
    @EnvironmentObject private var membership: Membership
    @StateObject private var store: ReaderStore
    @StateObject private var speech = ReadAloud()
    @StateObject private var listener: BookListener
    @ObservedObject private var preparer = BookAudioPreparer.shared
    @State private var showChapters = false
    @State private var showBookAudio = false
    /// The first time you listen to a book, a gentle offer to download its audio first.
    @State private var audioOffer: BookAudioOfferRequest?
    /// Whether this book's audio is all generated; worked out when the listening bar appears and
    /// whenever generation stops (it checks a file per sentence, too slow for every redraw).
    @State private var bookAudioComplete = true
    @State private var chapterToReveal: Int?
    @State private var showFontMenu = false
    @State private var controlsVisible: Bool
    @State private var hideTask: Task<Void, Never>?
    @State private var readerReady = false
    @State private var restoreRequest: ReaderRestoreRequest?
    @State private var showTheater = false
    @State private var theaterLookupPause: UUID?
    @State private var theaterLookupResumeTask: Task<Void, Never>?
    @State private var annotationAccent = Palette.accent
    /// The page's width when last laid out; rotating the iPad or resizing it in Split View re-wraps
    /// every line, so the reader goes back to the same place in the paragraph afterwards.
    @State private var readerWidth: CGFloat = 0
    @Environment(\.roomy) private var roomy
    @AppStorage("readerFontSize") private var fontSize = 21.0
    @ScaledMetric(relativeTo: .caption) private var chapterNumberWidth = 10.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    /// From the shelf: flies back out through the title instead of a plain slide.
    @Environment(\.closeBook) private var closeBook
    @Environment(\.readerOnScreen) private var onScreen

    /// The book's cover, for theater mode's highlight colour.
    private let coverURL: URL

    init(book: Book, repository: BookRepository, startsWithControlsHidden: Bool = false) {
        coverURL = repository.coverURL(book.id)
        _store = StateObject(wrappedValue: ReaderStore(book: book, repository: repository))
        _listener = StateObject(wrappedValue: BookListener(book: BookText.readingClauses(book)))
        _controlsVisible = State(initialValue: !startsWithControlsHidden || UIAccessibility.isVoiceOverRunning)
    }

    var body: some View {
        readerCore
            .modifier(TracksReadingTime())
            .onChange(of: membership.isPro) { _, pro in
                store.tierChanged()
                if !pro {
                    theaterLookupResumeTask?.cancel(); theaterLookupPause = nil
                    listener.theaterIsVisible = false; showTheater = false
                    listener.stop(); speech.stop()
                    Task { await TranslationService.releaseWhenIdle() }
                }
            }
            .onChange(of: store.selected?.id) { _, _ in speech.stop() }
            .modifier(ReaderChrome(view: self))
    }

    private var readerCore: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 23) {
                    chapterHeader.id("chapter-top")
                    ForEach(store.chapter.paragraphs) { paragraph in
                        VStack(alignment: .leading, spacing: 17) {
                            if let index = paragraph.sentences.firstIndex(where: { $0.id == store.selected?.id }) {
                                paragraphText(paragraph, range: 0..<(index + 1))
                                translationPanel
                                if index + 1 < paragraph.sentences.count {
                                    paragraphText(paragraph, range: (index + 1)..<paragraph.sentences.count)
                                }
                            } else {
                                paragraphText(paragraph)
                            }
                        }
                        .background(ReaderParagraphAnchor(paragraphID: paragraph.id))
                        .id(paragraph.id)
                    }
                    chapterNavigation.padding(.vertical, 18)
                }
                .padding(.horizontal, roomy ? 40 : 26).padding(.top, roomy ? 66 : 58).padding(.bottom, listener.isActive ? 150 : 64)
                .frame(maxWidth: readingMeasure, alignment: .leading).frame(maxWidth: .infinity)
                .background(ReaderScrollObserver(
                    enabled: readerReady, restore: restoreRequest,
                    onPosition: { if readerReady { store.recordPosition($0) } },
                    onRestored: {
                        readerReady = true; restoreRequest = nil; scheduleAutoHide()
                        NotificationCenter.default.post(name: BookEntrance.readerReady, object: nil) // the page is drawn
                    },
                    onSeek: { proxy.scrollTo($0, anchor: .top) },
                    onBlankTap: toggleControls, onInteraction: noteInteraction
                ))
            }
            .background(Palette.paper)
            .accessibilityIdentifier("readerScroll")
            .accessibilityLabel(store.book.title)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width.rounded() }) { width in
                defer { readerWidth = width }
                guard readerReady, readerWidth > 0, width != readerWidth, let position = store.state.scrollPosition else { return }
                beginRestore(position, proxy: proxy)
            }
            .onChange(of: listener.chapterIndex) { _, index in
                if listener.isActive || showTheater, index != store.state.chapterIndex { store.changeChapter(index) }
            }
            .onChange(of: listener.speakingParagraph) { _, id in
                guard !showTheater, let id, readerReady, listener.chapterIndex == store.state.chapterIndex else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) { proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: showTheater) { _, visible in
                guard !visible, let id = listener.speakingParagraph, readerReady,
                      listener.chapterIndex == store.state.chapterIndex else { return }
                proxy.scrollTo(id, anchor: .center)
            }
            .onChange(of: store.chapterChangeID) { _, _ in
                beginRestore(ReadingPosition(paragraphID: nil, fraction: 0, sentenceID: nil), proxy: proxy)
            }
            .task {
                await store.load()
                annotationAccent = await CoverAccent.load(coverURL)
                guard !Task.isCancelled else { return }
                // Left in theater mode last time (even if the app was closed since): open in it.
                if membership.allows(.theater), ReadingModeMemory.theater(store.book.id), !showTheater { openTheater(animated: false) }
                var position = store.state.scrollPosition ?? ReadingPosition(paragraphID: store.resumeParagraph, fraction: 0, sentenceID: store.state.sentenceID)
                if let id = position.paragraphID, !store.chapter.paragraphs.contains(where: { $0.id == id }) {
                    position = ReadingPosition(paragraphID: nil, fraction: 0, sentenceID: nil)
                }
                beginRestore(position, proxy: proxy)
            }
        }
        .confirmationDialog("下载离线声音", isPresented: Binding(get: { speech.needsDownload }, set: { speech.needsDownload = $0 }), titleVisibility: .visible) {
            Button("下载并朗读") { if membership.require(.listening) { speech.downloadAndPlay() } }
            Button("取消", role: .cancel) { speech.cancelDownloadPrompt() }
        } message: { Text("首次下载约 150 MB，安装后约占 122 MB。下载后可离线朗读。") }
        .alert("朗读", isPresented: Binding(get: { speech.error != nil }, set: { if !$0 { speech.error = nil } })) {
            Button("知道了") { speech.error = nil }
        } message: { Text(speech.error ?? "") }
    }

    /// The text column: about 34 characters of the chosen size per line, so a large iPad screen
    /// keeps a comfortable line length at every font size. Phones are narrower than the minimum.
    private var readingMeasure: CGFloat { min(max(720, fontSize * 34 + 52), 960) }

    /// The page's bars stretch edge to edge; what is on them lines up with the text column.
    private var barMeasure: CGFloat { readingMeasure - (roomy ? 28 : 0) }

    /// Hardware keyboard in the reader.
    fileprivate var readerCommands: [KeyCommand] {
        let free = !showChapters && !showFontMenu && !showTheater && store.word == nil && onScreen
        let index = store.state.chapterIndex
        return [
            KeyCommand(title: "返回书架", key: "[", enabled: free) { if let closeBook { closeBook() } else { dismiss() } },
            KeyCommand(title: "放大字号", key: "=", enabled: free && fontSize < 32) { fontSize = min(32, fontSize + 2) },
            KeyCommand(title: "缩小字号", key: "-", enabled: free && fontSize > 17) { fontSize = max(17, fontSize - 2) },
            KeyCommand(title: "上一章", key: .leftArrow, enabled: free && index > 0) { store.changeChapter(index - 1) },
            KeyCommand(title: "下一章", key: .rightArrow, enabled: free && index + 1 < store.book.chapters.count) { store.changeChapter(index + 1) },
            KeyCommand(title: "章节目录", key: "l", modifiers: [.command, .shift], enabled: free) {
                chapterToReveal = index > 0 ? index : nil
                showChapters = true
            },
            KeyCommand(title: listener.isActive ? "暂停或继续听书" : "听整本书", key: "p", modifiers: [.command, .shift], enabled: free) {
                if membership.require(.listening) { listener.isActive ? listener.togglePause() : startListening() }
            },
            KeyCommand(title: "影院模式", key: "t", modifiers: [.command, .shift], enabled: free) { openTheater() },
        ]
    }

    fileprivate func applyChrome<Content: View>(_ content: Content) -> some View {
        content
        .keyCommands(readerCommands)
        .sensoryFeedback(.impact(weight: .light), trigger: store.selected?.id) { _, new in new != nil }
        .sensoryFeedback(.selection, trigger: store.word) { _, new in new != nil }
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .top) {
            if controlsVisible { readerToolbar.transition(.opacity) }
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 0) {
                if membership.allows(.listening) && listener.isActive { listenBar.transition(.move(edge: .bottom).combined(with: .opacity)) }
                if controlsVisible { progressBar.transition(.opacity) }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: listener.isActive)
        }
        .overlay {
            if membership.allows(.theater) && showTheater {
                TheaterView(listener: listener, progress: listener.progress, coverURL: coverURL, annotations: store.wordAnnotations, onPlayFromStop: { beginListening(.theater) }, onLookup: theaterLookup, onClose: closeTheater)
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .statusBarHidden(showTheater && onScreen)
        .persistentSystemOverlays(showTheater && onScreen ? .hidden : .automatic)
    }

    fileprivate func applyDialogs<Content: View>(_ content: Content) -> some View {
        content
        .sheet(item: $audioOffer) { offer in
            BookAudioOfferSheet {
                audioOffer = nil
                preparer.start(store.book, fromChapter: store.state.chapterIndex)
            } listen: {
                audioOffer = nil
                listenNow(offer.start)
            }
        }
        // The voice download asked for by that offer (the listening bar's popover asks for its own).
        .confirmationDialog("下载离线声音", isPresented: Binding(get: { preparer.needsDownload && !showBookAudio }, set: { if !$0 { preparer.cancelDownloadPrompt() } }), titleVisibility: .visible) {
            Button("下载并生成全书音频") { if membership.require(.listening) { preparer.downloadAndStart() } }
            Button("取消", role: .cancel) { preparer.cancelDownloadPrompt() }
        } message: { Text("首次下载约 150 MB，安装后约占 122 MB。") }
        .confirmationDialog("下载离线声音", isPresented: Binding(get: { listener.needsDownload }, set: { if !$0 { listener.cancelDownloadPrompt() } }), titleVisibility: .visible) {
            Button("下载并开始听书") { if membership.require(.listening) { listener.downloadAndStart() } }
            Button("取消", role: .cancel) { listener.cancelDownloadPrompt() }
        } message: { Text("首次下载约 150 MB，安装后约占 122 MB。下载后可离线听书。") }
        .alert("听书", isPresented: Binding(get: { listener.error != nil }, set: { if !$0 { listener.error = nil } })) {
            Button("知道了") { listener.error = nil }
        } message: { Text(listener.error ?? "") }
        .alert("查词失败", isPresented: Binding(get: { store.wordError != nil }, set: { if !$0 { store.dismissWord() } })) {
            Button("重试") { store.retryWord() }
            Button("取消", role: .cancel) { store.dismissWord() }
        } message: { Text(store.wordError ?? "") }
        .sheet(isPresented: $showChapters) { chapterSheet }
        .onChange(of: showChapters) { _, _ in scheduleAutoHide() }
        .onChange(of: store.word) { _, _ in scheduleAutoHide() }
        .onChange(of: store.wordLoading) { _, loading in
            if loading {
                theaterLookupResumeTask?.cancel()
            } else if store.wordMeaning != nil || store.wordError != nil {
                scheduleTheaterLookupResume()
            }
        }
        .onChange(of: showFontMenu) { _, _ in scheduleAutoHide() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                speech.stop()
                store.cancel()
                if store.wordLoading { store.dismissWord() }
                Task { await TranslationService.releaseWhenIdle() }
            }
            if phase != .active { store.flushPosition(); hideTask?.cancel() }
            else { scheduleAutoHide() }
        }
        .onDisappear { hideTask?.cancel(); theaterLookupResumeTask?.cancel(); store.flushPosition(); store.cancel(); store.dismissWord(); speech.stop(); listener.stop() }
        #if DEBUG
        .task {
            // Test-only: -ReadleAutoTheater starts listening and opens theater mode by itself.
            // -ReadleTheaterOnly opens it silently.
            let args = ProcessInfo.processInfo.arguments
            guard args.contains("-ReadleAutoTheater") || args.contains("-ReadleTheaterOnly") else { return }
            try? await Task.sleep(for: .seconds(1.2))
            if args.contains("-ReadleAutoTheater") { startListening() }
            try? await Task.sleep(for: .seconds(0.6))
            openTheater()
        }
        #endif
        .alert("阅读记录", isPresented: Binding(get: { store.storageError != nil }, set: { if !$0 { store.storageError = nil } })) {
            Button("知道了") { store.storageError = nil }
        } message: { Text(store.storageError ?? "") }
    }

    private var progressBar: some View {
                HStack(spacing: 14) {
                    Text("\(store.state.chapterIndex + 1) / \(store.book.chapters.count)").font(.caption.monospacedDigit()).foregroundStyle(Palette.muted)
                    ProgressView(value: store.progress).tint(Palette.accent)
                    Text("\(Int(store.progress * 100))%").font(.caption.monospacedDigit()).foregroundStyle(Palette.muted)
                }
                .padding(.horizontal, 26).padding(.vertical, roomy ? 18 : 14)
                .frame(maxWidth: barMeasure).frame(maxWidth: .infinity)
                .background(Palette.paper)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("readerProgress")
    }

    private var listenBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "headphones").font(.body).foregroundStyle(Palette.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(listener.chapterTitle).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(listener.status).font(.caption).foregroundStyle(Palette.muted).lineLimit(1)
                    .accessibilityIdentifier("listenStatus")
            }
            Spacer(minLength: 8)
            bookAudioButton
            Button { openTheater() } label: {
                Image(systemName: "film").font(.body).frame(width: 44, height: 44).hoverEffect(.highlight)
            }
            .accessibilityLabel("影院模式")
            .accessibilityIdentifier("theaterOpen")
            Button { listener.togglePause() } label: {
                Image(systemName: listener.phase == .paused ? "play.fill" : "pause.fill")
                    .font(.title3).frame(width: 44, height: 44)
                    .contentTransition(.symbolEffect(.replace))
                    .hoverEffect(.highlight)
            }
            .accessibilityLabel(listener.phase == .paused ? "继续听书" : "暂停听书")
            .accessibilityIdentifier("listenToggle")
            Button { listener.stop() } label: {
                Image(systemName: "xmark").font(.subheadline.weight(.semibold)).frame(width: 44, height: 44).hoverEffect(.highlight)
            }
            .foregroundStyle(Palette.muted)
            .accessibilityLabel("停止听书")
            .accessibilityIdentifier("listenStop")
        }
        .foregroundStyle(Palette.accent)
        .buttonStyle(.plain)
        .padding(.leading, 20).padding(.trailing, 12).padding(.vertical, roomy ? 10 : 6)
        .frame(maxWidth: barMeasure).frame(maxWidth: .infinity)
        .background(Palette.paper)
        .overlay(alignment: .top) { Divider() }
        .sensoryFeedback(.selection, trigger: listener.phase == .paused)
        .task(id: preparer.isRunning(store.book.id)) {
            guard membership.allows(.listening), !preparer.isRunning(store.book.id) else { return }
            let counts = preparer.counts(store.book)
            bookAudioComplete = counts.total == 0 || counts.done >= counts.total
        }
        .accessibilityElement(children: .contain)
    }

    private func theaterLookup(_ word: String, _ unit: BookListener.Unit) {
        theaterLookupResumeTask?.cancel()
        theaterLookupPause = listener.pauseForWordLookup()
        let sentence = store.chapter.paragraphs.lazy.flatMap(\.sentences).first { sentence in
            guard unit.ids.contains(sentence.id) else { return false }
            let tokenizer = NLTokenizer(unit: .word)
            tokenizer.string = sentence.text
            return tokenizer.tokens(for: sentence.text.startIndex..<sentence.text.endIndex).contains {
                String(sentence.text[$0]).localizedCaseInsensitiveCompare(word) == .orderedSame
            }
        } ?? Sentence(id: unit.ids[0], text: unit.text)
        store.lookup(word, sentence: sentence)
        // Cached results can complete synchronously without a loading change.
        if !store.wordLoading, store.wordMeaning != nil || store.wordError != nil {
            scheduleTheaterLookupResume()
        }
    }

    private func scheduleTheaterLookupResume() {
        guard let id = theaterLookupPause else { return }
        theaterLookupResumeTask?.cancel()
        theaterLookupResumeTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard !Task.isCancelled, !store.wordLoading else { return }
            listener.resumeAfterWordLookup(id)
            theaterLookupPause = nil
            theaterLookupResumeTask = nil
        }
    }

    private func openTheater(animated: Bool = true) {
        guard membership.require(.theater) else { return }
        hideTask?.cancel()
        ReadingModeMemory.set(theater: true, for: store.book.id)
        // Resume theater, then the previous listening position, then the reader.
        if !listener.isActive {
            let point = listener.savedTheaterPoint ?? listener.savedPoint ?? readerPoint
            if point.chapter != store.state.chapterIndex { store.changeChapter(point.chapter) }
            listener.browse(at: point)
        }
        listener.theaterIsVisible = true
        if animated {
            withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .easeOut(duration: 0.45)) { showTheater = true }
        } else {
            var instant = Transaction(); instant.disablesAnimations = true
            withTransaction(instant) { showTheater = true }
        }
    }
    private func closeTheater() {
        ReadingModeMemory.set(theater: false, for: store.book.id)
        theaterLookupResumeTask?.cancel()
        if let id = theaterLookupPause { listener.resumeAfterWordLookup(id) }
        theaterLookupPause = nil
        listener.theaterIsVisible = false
        withAnimation(.easeOut(duration: 0.3)) { showTheater = false }
        scheduleAutoHide()
    }

    // Resume from where listening last stopped; the first time, start at the reader's current position.
    private func startListening(at sentenceID: Int? = nil) {
        guard membership.require(.listening) else { return }
        speech.stop()
        if let sentenceID {
            listener.start(at: ListenPoint(chapter: store.state.chapterIndex, sentence: sentenceID))
        } else if let saved = listener.savedPoint {
            listener.start(at: saved)
        } else {
            listener.start(at: readerPoint)
        }
        noteInteraction()
    }

    /// Starting to listen. The first time for a book whose audio isn't generated, offer to download
    /// it first (once per book); otherwise, or after that, just start.
    private func beginListening(_ start: BookAudioOfferRequest.Start) {
        guard membership.require(.listening) else { return }
        let key = "readle.audioOffer.\(store.book.id.uuidString)"
        if !UserDefaults.standard.bool(forKey: key), !preparer.isRunning(store.book.id) {
            let counts = preparer.counts(store.book)
            if counts.total > 0, counts.done < counts.total {
                UserDefaults.standard.set(true, forKey: key)
                audioOffer = BookAudioOfferRequest(start: start)
                return
            }
        }
        listenNow(start)
    }

    private func listenNow(_ start: BookAudioOfferRequest.Start) {
        switch start {
        case .reader: startListening()
        case .theater: playFromTheater()
        }
    }

    /// Play in theater mode: the voice starts from the sentence on screen.
    private func playFromTheater() {
        guard membership.require(.listening) else { return }
        speech.stop()
        if let point = listener.currentPoint { listener.start(at: point) } else { startListening() }
    }

    /// The sentence at the top of what the reader is showing.
    private var readerPoint: ListenPoint {
        let position = store.state.scrollPosition
        let paragraphs = store.chapter.paragraphs
        let id = position?.sentenceID
            ?? paragraphs.first(where: { $0.id == position?.paragraphID })?.sentences.first?.id
            ?? paragraphs.first?.sentences.first?.id ?? 0
        return ListenPoint(chapter: store.state.chapterIndex, sentence: id)
    }

    /// Toolbar buttons: compact on iPhone, so the title keeps room; full 44-point targets on iPad.
    private var toolSize: CGSize { roomy ? CGSize(width: 44, height: 44) : CGSize(width: 36, height: 40) }

    private func lockBadge(_ locked: Bool) -> some View {
        Group {
            if locked { Image(systemName: "lock.fill").font(.system(size: roomy ? 10 : 9)).background(Palette.paper) }
        }
    }

    private var readerToolbar: some View {
        HStack(spacing: roomy ? 10 : 6) {
            Button { if let closeBook { closeBook() } else { dismiss() } } label: {
                Image(systemName: "chevron.left").frame(width: roomy ? 44 : 40, height: roomy ? 44 : 40).hoverEffect(.highlight)
            }
                .accessibilityLabel("返回书架")
                .accessibilityIdentifier("readerBack")
            Text(store.book.title).font(.headline).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("readerTitle")
            Button { if membership.require(.listening) { listener.isActive ? listener.togglePause() : beginListening(.reader) } } label: {
                Image(systemName: listener.isActive ? "headphones.circle.fill" : "headphones")
                    .overlay(alignment: .bottomTrailing) { lockBadge(!membership.allows(.listening)) }
                    .frame(width: toolSize.width, height: toolSize.height).hoverEffect(.highlight)
            }
            .accessibilityLabel(listener.isActive ? "暂停或继续听书" : "听整本书")
            .accessibilityIdentifier("listenBook")
            Button { openTheater() } label: {
                Image(systemName: "film")
                    .overlay(alignment: .bottomTrailing) { lockBadge(!membership.allows(.theater)) }
                    .frame(width: toolSize.width, height: toolSize.height).hoverEffect(.highlight)
            }
                .accessibilityLabel("影院模式")
                .accessibilityIdentifier("theaterOpenTop")
            Button { showFontMenu = true } label: {
                Image(systemName: "textformat.size").frame(width: toolSize.width, height: toolSize.height).hoverEffect(.highlight)
            }
                .accessibilityLabel("阅读字号")
                .popover(isPresented: $showFontMenu) {
                    HStack(spacing: 0) {
                        Button { fontSize = max(17, fontSize - 2) } label: {
                            Image(systemName: "textformat.size.smaller").frame(width: 56, height: 44).hoverEffect(.highlight)
                        }
                        .disabled(fontSize <= 17).accessibilityLabel("缩小字号")
                        Divider().frame(height: 24)
                        Text("\(Int(fontSize))").font(.subheadline).monospacedDigit().foregroundStyle(Palette.muted)
                            .frame(width: 44).accessibilityLabel("字号 \(Int(fontSize))")
                        Divider().frame(height: 24)
                        Button { fontSize = min(32, fontSize + 2) } label: {
                            Image(systemName: "textformat.size.larger").frame(width: 56, height: 44).hoverEffect(.highlight)
                        }
                        .disabled(fontSize >= 32).accessibilityLabel("放大字号")
                    }
                    .font(.body).foregroundStyle(Palette.accent)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .sensoryFeedback(.selection, trigger: fontSize)
                    .presentationCompactAdaptation(.popover)
                }
            Button {
                chapterToReveal = store.state.chapterIndex > 0 ? store.state.chapterIndex : nil
                showChapters = true
            } label: {
                Image(systemName: "list.bullet").frame(width: toolSize.width, height: toolSize.height).hoverEffect(.highlight)
            }
                .accessibilityLabel("章节目录")
        }
        .font(roomy ? .title3 : .body)
        .buttonStyle(.plain)
        .foregroundStyle(Palette.accent)
        .padding(.horizontal, roomy ? 24 : 16).padding(.vertical, roomy ? 8 : 6)
        .background(Palette.paper)
    }

    private func paragraphText(_ paragraph: Paragraph, range: Range<Int>? = nil) -> some View {
        ParagraphView(paragraph: paragraph, sentenceRange: range, selectedID: store.selected?.id, speakingIDs: listener.speakingIDs, fontSize: fontSize, annotations: store.wordAnnotations.filter { id, _ in paragraph.sentences.contains { $0.id == id } }, annotationColor: annotationAccent, onWord: { word, sentence in
            hideTask?.cancel()
            store.lookup(word, sentence: sentence)
        }) { sentence in
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                store.selectForListening(sentence)
            }
            noteInteraction()
        }
    }

    private func beginRestore(_ position: ReadingPosition, proxy: ScrollViewProxy) {
        readerReady = false
        restoreRequest = ReaderRestoreRequest(position: position)
        DispatchQueue.main.async {
            if let id = position.paragraphID { proxy.scrollTo(id, anchor: .top) }
            else { proxy.scrollTo("chapter-top", anchor: .top) }
        }
    }

    private func toggleControls() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { controlsVisible.toggle() }
        scheduleAutoHide()
    }

    private func noteInteraction() { scheduleAutoHide() }

    private func scheduleAutoHide() {
        hideTask?.cancel()
        guard controlsVisible, readerReady, !showChapters, !showFontMenu, store.word == nil, !UIAccessibility.isVoiceOverRunning else { return }
        hideTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { controlsVisible = false }
        }
    }

    private var chapterHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(store.chapter.title).font(.system(.title, design: .serif).weight(.medium))
            Text(membership.allows(.listening) ? "轻点单词查义 · 长按句子朗读" : "轻点单词查义 · 长按句子翻译").font(.caption).foregroundStyle(Palette.muted)
            Divider().padding(.top, 4)
        }
        .padding(.top, 28).padding(.bottom, 4)
    }

    private var translationPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let translation = store.translation {
                Text(translation)
                    .font(.system(size: fontSize * 0.9, design: .serif))
                    .foregroundStyle(Palette.ink)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("sentenceTranslation")
            }
            if let error = store.error {
                Text(error).font(.caption).foregroundStyle(Palette.muted)
            }
            if let selected = store.selected {
                HStack(spacing: 20) {
                    if store.translating {
                        Button { store.cancel() } label: {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("取消翻译")
                            }.font(.caption.weight(.medium)).frame(minHeight: 44).hoverEffect(.highlight)
                        }
                    } else if store.translation == nil {
                        Button { store.select(selected, retry: store.error != nil) } label: {
                            let exhausted = !membership.isPro && membership.translationsRemaining == 0
                            Label(exhausted ? "升级解锁翻译" : store.error == nil ? "AI 翻译" : "重试翻译",
                                  systemImage: exhausted ? "lock" : "translate")
                                .font(.caption.weight(.medium)).frame(minHeight: 44).hoverEffect(.highlight)
                        }
                        .accessibilityIdentifier("translateSentence")
                    }
                    if membership.allows(.listening) {
                        Button { startListening(at: selected.id) } label: {
                            Label("从这里听", systemImage: "headphones").font(.caption.weight(.medium)).frame(minHeight: 44).hoverEffect(.highlight)
                        }
                        .accessibilityIdentifier("listenFromHere")
                        speechButton(selected.text, id: "sentence-original", title: "朗读原句")
                    }
                }
                if !membership.isPro {
                    Text("免费 AI 翻译与查词剩余 \(membership.translationsRemaining) 次")
                        .font(.caption)
                        .foregroundStyle(Palette.muted)
                }
            }
        }
        .foregroundStyle(Palette.accent)
        .transition(.opacity)
        .accessibilityElement(children: .contain)
    }

    private func speechButton(_ text: String, id: String, title: String) -> some View {
        let active = speech.activeID == id
        let label = !active ? title : (speech.isPreparing ? "取消" : (speech.isPaused ? "继续" : "暂停"))
        let symbol = !active ? "speaker.wave.2" : (speech.isPreparing ? "xmark" : (speech.isPaused ? "play.fill" : "pause.fill"))
        return Button {
            guard membership.require(.listening) else { return }
            listener.pause()
            speech.toggle(text, id: id)
        } label: {
            Label(label, systemImage: symbol)
                .font(.caption.weight(.medium)).frame(minHeight: 44).hoverEffect(.highlight)
        }
        .foregroundStyle(Palette.accent)
        .accessibilityLabel(active ? "\(label)朗读" : title)
        .accessibilityIdentifier("speak-" + id)
    }

    private var speechStatus: some View {
        Text(speech.status).font(.caption).foregroundStyle(Palette.muted)
            .accessibilityIdentifier("speechStatus")
            .accessibilityAddTraits(.updatesFrequently)
    }

    private var chapterNavigation: some View {
        HStack {
            if store.state.chapterIndex > 0 {
                Button("上一章", systemImage: "arrow.left") { store.changeChapter(store.state.chapterIndex - 1) }
            }
            Spacer()
            if store.state.chapterIndex + 1 < store.book.chapters.count {
                Button { store.changeChapter(store.state.chapterIndex + 1) } label: {
                    HStack { Text("下一章"); Image(systemName: "arrow.right") }
                }
            } else {
                Text("本书完").foregroundStyle(Palette.muted)
                    // Reaching the end of the last chapter counts the book as read (我的 · 已读完).
                    .onAppear { if onScreen { ReadingStats.shared.markFinished(store.book.id) } }
            }
        }.font(.subheadline)
    }

    // Generate every English sentence once, so listening from any point plays without waiting.
    @ViewBuilder private var bookAudioSection: some View {
        let counts = preparer.counts(store.book)
        if counts.total > 0 {
            VStack(alignment: .leading, spacing: 12) {
                Text("全书音频")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Palette.muted)
                    .accessibilityAddTraits(.isHeader)
                if preparer.isRunning(store.book.id) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("正在生成全书音频").font(.subheadline.weight(.medium))
                            Spacer()
                            Text("\(counts.done.formatted()) / \(counts.total.formatted()) 句").font(.footnote).monospacedDigit().foregroundStyle(Palette.muted)
                        }
                        ProgressView(value: Double(counts.done), total: Double(max(counts.total, 1)))
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("bookAudioProgress")
                    Button("暂停生成", systemImage: "pause") { preparer.pause() }
                } else if counts.done >= counts.total {
                    LabeledContent {
                        Text(ByteCountFormatter.string(fromByteCount: BookAudio.size(store.book.id), countStyle: .file)).monospacedDigit()
                    } label: {
                        Label("全书音频已就绪", systemImage: "checkmark.circle.fill").foregroundStyle(Palette.accent)
                    }
                    .accessibilityIdentifier("bookAudioReady")
                } else {
                    Button {
                        guard membership.require(.listening) else { return }
                        preparer.start(store.book, fromChapter: store.state.chapterIndex)
                    } label: {
                        LabeledContent {
                            if counts.done > 0 { Text("\(counts.done.formatted()) / \(counts.total.formatted()) 句").monospacedDigit() }
                        } label: {
                            if counts.older > 0 && counts.done + counts.older == counts.total {
                                Label("更新离线朗读", systemImage: "arrow.clockwise")
                            } else {
                                Label(counts.done + counts.older > 0 ? "继续生成全书音频" : "生成全书音频", systemImage: "arrow.down.circle")
                            }
                        }
                    }
                    .accessibilityIdentifier("prepareBookAudio")
                }
                Group {
                    if preparer.isRunning(store.book.id) {
                        Text("生成时请保持句读院打开，离开应用后会暂停。听书时可以继续生成。")
                    } else if counts.older > 0 {
                        Text("已有音频可以继续播放。更新会逐句替换需要重新生成或对齐的音频。")
                    } else {
                        Text("生成整本书的朗读音频后，可以从任意句子开始听。可随时暂停，下次继续。")
                    }
                }
                .font(.footnote)
                .foregroundStyle(Palette.muted)
            }
            .padding(20)
            .frame(width: 320, alignment: .leading)
        }
    }

    /// In the listening bar: download the whole book's audio. A ring while it is being generated;
    /// gone once it is all ready.
    @ViewBuilder private var bookAudioButton: some View {
        let running = preparer.isRunning(store.book.id)
        if membership.allows(.listening), running || !bookAudioComplete {
            Button { showBookAudio = true } label: {
                Group {
                    if running {
                        let counts = preparer.counts(store.book) // cheap while running
                        ZStack {
                            Circle().stroke(Palette.accent.opacity(0.18), lineWidth: 2.5)
                            Circle().trim(from: 0, to: Double(counts.done) / Double(max(counts.total, 1)))
                                .stroke(Palette.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                        }
                        .frame(width: 20, height: 20)
                    } else {
                        Image(systemName: "arrow.down.circle").font(.body)
                    }
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .hoverEffect(.highlight)
            }
            .accessibilityLabel(running ? "正在生成全书音频" : "生成全书音频")
            .accessibilityIdentifier("bookAudioOpen")
            .popover(isPresented: $showBookAudio) {
                bookAudioSection
                    .tint(Palette.accent)
                    .presentationCompactAdaptation(.popover)
                    .confirmationDialog("下载离线声音", isPresented: Binding(get: { preparer.needsDownload }, set: { if !$0 { preparer.cancelDownloadPrompt() } }), titleVisibility: .visible) {
                        Button("下载并生成全书音频") { if membership.require(.listening) { preparer.downloadAndStart() } }
                        Button("取消", role: .cancel) { preparer.cancelDownloadPrompt() }
                    } message: { Text("首次下载约 150 MB，安装后约占 122 MB。") }
                    .alert("全书音频", isPresented: Binding(get: { preparer.error != nil }, set: { if !$0 { preparer.error = nil } })) {
                        Button("知道了") { preparer.error = nil }
                    } message: { Text(preparer.error ?? "") }
            }
        }
    }

    private static let contentsPaper = Color(UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(red: 0.083, green: 0.078, blue: 0.072, alpha: 1)
        }
        return UIColor(red: 0.973, green: 0.965, blue: 0.948, alpha: 1)
    })

    private static let currentChapterTint = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.76, green: 0.66, blue: 0.49, alpha: 1)
            : UIColor(red: 0.38, green: 0.28, blue: 0.15, alpha: 1)
    })

    private var chapterSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text("共 \(store.book.chapters.count) 章")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 12)
                    .overlay(alignment: .bottom) { Divider().padding(.horizontal, 24) }

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(store.book.chapters.indices, id: \.self) { index in
                                contentsRow(at: index)
                                    .id(index)
                            }
                        }
                        .padding(.bottom, 16)
                        .onGeometryChange(for: Bool.self, of: { $0.size.height > 0 }) { laidOut in
                            guard laidOut, let chapterToReveal else { return }
                            proxy.scrollTo(chapterToReveal, anchor: .center)
                            self.chapterToReveal = nil
                        }
                    }
                    .accessibilityIdentifier("chapterContents")
                }
                // Keep the gutters outside the scrollable content so centering a chapter
                // cannot shift the rows horizontally during presentation.
                .padding(.horizontal, 24)
            }
            .background(Self.contentsPaper.ignoresSafeArea())
            .tint(Palette.accent)
            .toolbarBackground(Self.contentsPaper, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationTitle("章节目录").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showChapters = false }.keyboardShortcut(.cancelAction) } }
        }
    }

    private func contentsRow(at index: Int) -> some View {
        let current = index == store.state.chapterIndex
        let numberWidth = chapterNumberWidth * CGFloat(max(3, String(store.book.chapters.count).count))
        return Button {
            store.changeChapter(index)
            showChapters = false
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(String(format: "%02d", index + 1))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Palette.muted)
                    .frame(width: numberWidth, alignment: .leading)
                Text(store.book.chapters[index].title)
                    .font(.system(.body, design: .serif).weight(current ? .semibold : .regular))
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 12)
            .frame(minHeight: 52)
            .background {
                if current { Rectangle().fill(Self.currentChapterTint.opacity(0.09)) }
            }
            .contentShape(Rectangle())
            .hoverEffect(.highlight)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(current ? .isSelected : [])
        .overlay(alignment: .bottom) { Divider() }
    }
}

// MARK: - Theater mode (影院模式)
// A dark, full-screen view of the book being read aloud: the current sentence is sharp and
// centered; the others blur and fade with distance, and everything glides on as the voice moves on.
struct TheaterView: View {
    @ObservedObject var listener: BookListener
    let progress: ListenProgress
    let coverURL: URL
    let annotations: [Int: [String: String]]
    let onPlayFromStop: () -> Void
    let onLookup: (String, BookListener.Unit) -> Void
    let onClose: () -> Void
    /// The highlight for words already read, taken from the book's cover.
    @State private var accent = CoverAccent.fallback
    @State private var controlsVisible = true
    /// Buttons keep taking taps until they have fully faded, so a tap during the fade still counts
    /// instead of falling through to the sentences underneath.
    @State private var buttonsTappable = true
    @State private var hideTask: Task<Void, Never>?
    @State private var dragTranslation: CGFloat = 0
    @State private var swipe: TheaterSwipe?
    @State private var spokenOffset: CGFloat = 0
    @State private var manualScroll: TheaterManualScroll?
    /// True only while a swipe is in progress. It also goes false when the system takes a swipe
    /// away mid-way (the swipe up to leave the app), which never calls onEnded.
    @GestureState private var swiping = false
    @Environment(\.scenePhase) private var scenePhase
    /// Measured sentence heights; a plain reference so recording them never redraws anything.
    @State private var heights = RowHeights()
    @State private var screenHeight: CGFloat = 800
    @State private var showHint = false
    @AppStorage("theaterHintShown") private var hintShown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.roomy) private var roomy

    private var type: TheaterType { roomy ? .pad : .phone }
    private var presentedIndex: Int { swipe?.index ?? listener.currentIndex }
    private var readingOffset: CGFloat {
        if let manualScroll, manualScroll.point == listener.currentPoint { return manualScroll.offset }
        return spokenOffset
    }
    private var glide: Animation? { reduceMotion ? nil : .spring(duration: 0.38, bounce: 0) }
    /// Words fill in one by one only while the voice is going (or held for a word lookup). Paused
    /// or never started, the sentence in focus is simply fully lit, so it can be read.
    private var listening: Bool {
        listener.phase == .playing || listener.phase == .preparing || listener.isPausedForWordLookup
    }

    private var columnPosition: (sentence: CGFloat, offset: CGFloat) {
        guard let swipe else { return (CGFloat(listener.currentIndex), readingOffset) }
        let scrolled = scrollWithinSentence(dragTranslation, from: swipe)
        if scrolled != 0 {
            return (CGFloat(swipe.index), swipe.readingOffset + scrolled)
        }
        let step = dragTranslation < 0 ? 1 : -1
        let distance = travel(from: swipe, to: swipe.index + step)
        guard abs(distance) > 1, distance * dragTranslation > 0 else {
            return (CGFloat(swipe.index), swipe.readingOffset + dragTranslation * 0.3)
        }
        let fraction = min(dragTranslation / distance, 1)
        return (CGFloat(swipe.index) + CGFloat(step) * fraction,
                swipe.readingOffset * (1 - fraction))
    }

    private static let ink = Color(white: 0.93)
    var body: some View {
        GeometryReader { geo in
            ZStack {
                ZStack {
                Color.black.ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { toggleControls() }

                // Keep one text column. Moving a duplicate blurred layer made the
                // controls especially expensive to render while the user dragged.
                theaterColumn
                    .animation(glide, value: presentedIndex)
                    .animation(glide, value: spokenOffset)
                    .id(listener.chapterIndex)
                    .frame(maxWidth: type.measure)
                    .padding(.horizontal, roomy ? 48 : 34)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .mask(viewportMask)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { screenHeight = $0 }
                .accessibilityElement(children: .contain)
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: listener.move(to: listener.currentIndex + 1)
                    case .decrement: listener.move(to: listener.currentIndex - 1)
                    @unknown default: break
                    }
                }
                }
                .gesture(scrollThroughSentences)

                if showHint {
                    VStack {
                        Text("上下滑动切换句子 · 轻点显示按钮")
                            .font(.footnote).foregroundStyle(Self.ink.opacity(0.7))
                            .padding(.horizontal, 16).padding(.vertical, 9)
                            .background(.white.opacity(0.08), in: Capsule())
                            .padding(.top, 76)
                        Spacer()
                    }
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }

                controls.opacity(controlsVisible ? 1 : 0).allowsHitTesting(buttonsTappable)
                    .task(id: controlsVisible) {
                        if controlsVisible { buttonsTappable = true; return }
                        try? await Task.sleep(for: .milliseconds(450))
                        if !Task.isCancelled, !controlsVisible { buttonsTappable = false }
                    }
            }
        }
        .onReceive(progress.$fraction) { fraction in
            guard swipe == nil else { return }
            let offset = offsetForReading(fraction)
            if spokenOffset != offset { spokenOffset = offset }
        }
        .onChange(of: listener.currentPoint) { _, _ in
            if manualScroll?.point != listener.currentPoint { manualScroll = nil }
        }
        .onChange(of: listener.chapterIndex) { _, _ in clearSwipe() }
        .onChange(of: swiping) { _, active in if !active { settleSwipe() } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { settleSwipe() } }
        // Dark for this screen only (it hides the status bar): forcing the whole app dark would
        // also turn the shelf behind it into the night room.
        .environment(\.colorScheme, .dark)
        .task(id: coverURL) { accent = await CoverAccent.load(coverURL) }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            scheduleHide()
            if !hintShown {
                hintShown = true
                withAnimation(.easeOut(duration: 0.4).delay(0.5)) { showHint = true }
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(4.5))
                    withAnimation(.easeOut(duration: 0.6)) { showHint = false }
                }
            }
        }
        .onDisappear {
            hideTask?.cancel()
            UIApplication.shared.isIdleTimerDisabled = BookAudioPreparer.shared.running
        }
        .onChange(of: listener.phase) { _, phase in
            // Between sentences the listener briefly reports .preparing; only a real pause or stop
            // should bring the controls back.
            switch phase {
            case .paused where listener.isPausedForWordLookup: break
            case .paused, .idle: hideTask?.cancel(); withAnimation(.easeOut(duration: 0.2)) { controlsVisible = true }
            case .playing, .preparing: if controlsVisible && hideTask == nil { scheduleHide() }
            }
        }
        .accessibilityAction(.escape) { onClose() }
        .keyCommands(theaterCommands)
    }

    /// Hardware keyboard: space plays or pauses, the arrows move between sentences, Esc leaves.
    private var theaterCommands: [KeyCommand] {
        [
            KeyCommand(title: listener.phase == .playing ? "暂停" : "播放", key: .space, modifiers: []) {
                if listener.phase == .idle { onPlayFromStop() } else { listener.togglePause() }
                showControlsBriefly()
            },
            KeyCommand(title: "下一句", key: .downArrow, modifiers: [], enabled: listener.canMove(to: listener.currentIndex + 1)) {
                withAnimation(glide) { listener.move(to: listener.currentIndex + 1) }
            },
            KeyCommand(title: "上一句", key: .upArrow, modifiers: [], enabled: listener.canMove(to: listener.currentIndex - 1)) {
                withAnimation(glide) { listener.move(to: listener.currentIndex - 1) }
            },
            KeyCommand(title: "退出影院模式", key: .escape, modifiers: []) { onClose() },
        ]
    }

    private var theaterColumn: some View {
        let position = columnPosition
        return TheaterColumn(units: listener.units, chapterIndex: listener.chapterIndex,
                      currentIndex: presentedIndex,
                      range: visibleRange, reduceMotion: reduceMotion, heights: heights,
                      position: position.sentence, readingOffset: position.offset,
                      progress: progress, accent: accent, type: type,
                      annotations: annotations, karaoke: listening,
                      animatesWords: swipe == nil && listener.phase == .playing,
                      onTap: { toggleControls() },
                      onLookup: { word, unit in hideTask?.cancel(); controlsVisible = false; onLookup(word, unit) })
            .equatable()
    }

    private var viewportMask: some View {
        LinearGradient(stops: [.init(color: .clear, location: 0),
                               .init(color: .black.opacity(controlsVisible ? 0.28 : 0.46), location: 0.1),
                               .init(color: .black, location: 0.22),
                               .init(color: .black, location: 0.78),
                               .init(color: .black.opacity(controlsVisible ? 0.28 : 0.46), location: 0.9),
                               .init(color: .clear, location: 1)],
                       startPoint: .top, endPoint: .bottom)
    }

    /// Only the sentences near the current one are built; the rest are far off screen.
    private var visibleRange: Range<Int> {
        let count = listener.units.count
        guard count > 0 else { return 0..<0 }
        let current = min(max(presentedIndex, 0), count - 1)
        let reach = 6
        return max(0, current - reach)..<min(count, current + reach + 1)
    }


    private var controls: some View {
        VStack {
            HStack(spacing: 16) {
                Button { onClose() } label: {
                    Image(systemName: "xmark").font(.body.weight(.medium)).frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                        .hoverEffect(.lift)
                }
                .accessibilityLabel("退出影院模式")
                .accessibilityIdentifier("theaterClose")
                TheaterProgressIndicator(listener: listener, progress: progress, ink: Self.ink)
                    .frame(maxWidth: .infinity)
                TimelineView(.periodic(from: Date(timeIntervalSince1970: 0), by: 60)) { context in
                    Text(context.date, format: .dateTime.hour().minute())
                        .font(.caption.monospacedDigit())
                        .lineLimit(1)
                        .fixedSize()
                        .accessibilityIdentifier("theaterClock")
                }
                .frame(minHeight: 44, alignment: .trailing)
            }
            .padding(.horizontal, roomy ? 28 : 20)
            .padding(.top, roomy ? 8 : 0)
            Spacer()
            VStack(spacing: 10) {
                // Wider gaps so the three buttons read as one calm, evenly spaced row.
                HStack(spacing: 64) {
                    Button { listener.skip(-1); showControlsBriefly() } label: {
                        Image(systemName: "backward.fill").font(.title3).frame(width: 52, height: 52)
                            .background(.ultraThinMaterial, in: Circle())
                            .contentShape(Circle())
                            .hoverEffect(.lift)
                    }
                    .accessibilityLabel("上一句")
                    .accessibilityIdentifier("theaterPrevious")
                    .disabled(!listener.canGoBack)
                    Button {
                        if listener.phase == .idle { onPlayFromStop() } else { listener.togglePause() }
                        showControlsBriefly()
                    } label: {
                        Image(systemName: listener.phase == .playing || listener.phase == .preparing ? "pause.fill" : "play.fill")
                            .font(.title2).frame(width: 64, height: 64)
                            .background(.ultraThinMaterial, in: Circle())
                            .contentTransition(.symbolEffect(.replace))
                            .hoverEffect(.lift)
                    }
                    .accessibilityLabel(listener.phase == .playing ? "暂停" : "播放")
                    .accessibilityIdentifier("theaterPlayPause")
                    Button { listener.skip(1); showControlsBriefly() } label: {
                        Image(systemName: "forward.fill").font(.title3).frame(width: 52, height: 52)
                            .background(.ultraThinMaterial, in: Circle())
                            .contentShape(Circle())
                            .hoverEffect(.lift)
                    }
                    .accessibilityLabel("下一句")
                    .accessibilityIdentifier("theaterNext")
                    .disabled(!listener.canGoForward)
                }
            }
            .padding(.bottom, roomy ? 56 : 40)
        }
        // Kept faint so the eye stays on the sentence.
        .foregroundStyle(Self.ink.opacity(0.5))
        .buttonStyle(.plain)
    }

    // MARK: Swipe through sentences

    private func height(_ index: Int) -> CGFloat { heights.value(index, chapter: listener.chapterIndex) ?? 110 }

    /// Keep the next few spoken lines in the clear band during a long sentence.
    private func offsetForReading(_ fraction: Double) -> CGFloat {
        let height = heights.value(listener.currentIndex, chapter: listener.chapterIndex) ?? 0
        let band = screenHeight * SentenceColumn.clearBand
        guard height > band else { return 0 }
        let line = type.line // one line of the serif plus its line spacing
        let lines = max(1, Int(((height + 22) / line).rounded()))
        let visible = max(1, Int(band / line))
        let reading = Int(Double(lines) * min(max(fraction, 0), 0.999))
        let shift = min(max(reading - (visible - 2), 0), max(lines - visible, 0))
        return -min(CGFloat(shift) * line, height - band)
    }

    /// A swipe that reveals more of a tall sentence stays on that sentence.
    private func scrollWithinSentence(_ translation: CGFloat, from swipe: TheaterSwipe) -> CGFloat {
        let overflow = max(0, height(swipe.index) - screenHeight * SentenceColumn.clearBand)
        return min(0, max(-overflow, swipe.readingOffset + translation)) - swipe.readingOffset
    }

    private func travel(from swipe: TheaterSwipe, to target: Int) -> CGFloat {
        guard listener.units.indices.contains(target) else { return 0 }
        let currentHeight = height(swipe.index)
        let targetHeight = height(target)
        let currentTop = SentenceColumn.anchorTop(height: currentHeight, in: screenHeight) + swipe.readingOffset
        let targetTop = SentenceColumn.anchorTop(height: targetHeight, in: screenHeight)
        let distance = target > swipe.index ? currentHeight + type.rowSpacing : -(targetHeight + type.rowSpacing)
        return targetTop - currentTop - distance
    }

    private static let swipeThreshold: CGFloat = 44

    private func clearSwipe() {
        swipe = nil
        dragTranslation = 0
        spokenOffset = offsetForReading(progress.fraction)
    }

    private func settleSwipe() {
        guard swipe != nil else { return }
        withAnimation(glide) { clearSwipe() }
        scheduleHide()
    }

    private var scrollThroughSentences: some Gesture {
        DragGesture(minimumDistance: 8)
            .updating($swiping) { _, state, _ in state = true }
            .onChanged { value in
                guard listener.units.indices.contains(listener.currentIndex) else { return }
                let start = swipe ?? TheaterSwipe(index: listener.currentIndex, readingOffset: readingOffset)
                if swipe == nil {
                    swipe = start
                    hideTask?.cancel()
                    if showHint { withAnimation(.easeOut(duration: 0.2)) { showHint = false } }
                }
                dragTranslation = value.translation.height
            }
            .onEnded { value in
                guard let swipe else { return }
                let translation = value.translation.height
                let scrolled = scrollWithinSentence(translation, from: swipe)
                let projected = abs(translation) >= Self.swipeThreshold ? translation : value.predictedEndTranslation.height
                withAnimation(glide) {
                    if scrolled != 0 {
                        if swipe.index == listener.currentIndex, let point = listener.currentPoint {
                            manualScroll = TheaterManualScroll(point: point, offset: swipe.readingOffset + scrolled)
                        }
                    } else if projected <= -Self.swipeThreshold, listener.canMove(to: swipe.index + 1) {
                        listener.move(to: swipe.index + 1)
                    } else if projected >= Self.swipeThreshold, listener.canMove(to: swipe.index - 1) {
                        listener.move(to: swipe.index - 1)
                    }
                    clearSwipe()
                }
                scheduleHide()
            }
    }

    private func toggleControls() {
        withAnimation(.easeOut(duration: 0.2)) { controlsVisible.toggle() }
        if controlsVisible { scheduleHide() }
    }
    private func showControlsBriefly() {
        withAnimation(.easeOut(duration: 0.2)) { controlsVisible = true }
        scheduleHide()
    }
    private func scheduleHide() {
        hideTask?.cancel()
        // Hidden while the voice plays or while reading silently; a pause keeps them up.
        guard listener.phase != .paused, !UIAccessibility.isVoiceOverRunning else { return }
        hideTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            withAnimation(.easeOut(duration: 0.4)) { controlsVisible = false }
            hideTask = nil
        }
    }
}

/// Theater mode's type and spacing: larger on iPad, which is read from further away, with the
/// sentence held to a comfortable measure instead of running across the whole screen.
struct TheaterType: Equatable {
    let size: CGFloat
    let lineSpacing: CGFloat
    let rowSpacing: CGFloat
    /// One line of the serif plus its line spacing, for keeping long sentences in view.
    let line: CGFloat
    let caption: CGFloat
    /// Room above a sentence for the word glosses printed over it.
    let glossRoom: CGFloat
    let measure: CGFloat

    static let phone = TheaterType(size: 29, lineSpacing: 22, rowSpacing: 30, line: 56, caption: 12, glossRoom: 16, measure: .infinity)
    static let pad = TheaterType(size: 36, lineSpacing: 27, rowSpacing: 36, line: 70, caption: 14, glossRoom: 19, measure: 780)
}

private struct TheaterManualScroll {
    let point: ListenPoint
    let offset: CGFloat
}

private struct TheaterSwipe {
    let index: Int
    let readingOffset: CGFloat
}

private struct TheaterProgressIndicator: View {
    let listener: BookListener
    @ObservedObject var progress: ListenProgress
    let ink: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let done = listener.bookProgress(within: progress.fraction)
        let percent = Int((done * 100).rounded(.down))
        HStack(spacing: 10) {
            GeometryReader { geometry in
                Capsule().fill(.white.opacity(0.12))
                .frame(height: 3)
                .overlay(alignment: .leading) {
                    Capsule().fill(ink.opacity(0.55)).frame(width: max(3, geometry.size.width * done), height: 3)
                        .animation(reduceMotion ? nil : .linear(duration: 0.25), value: done)
                }
            }
            .frame(maxWidth: 150)
            .frame(height: 3)
            Text("\(percent)%")
                .font(.caption.monospacedDigit()).foregroundStyle(ink.opacity(0.4))
                .frame(width: 34, alignment: .leading)
        }
        .frame(height: 44)
        .accessibilityElement()
        .accessibilityLabel("已听 \(percent)%")
    }
}

/// Splits the reader's long modifier chain so the type checker stays fast.
private struct ReaderChrome: ViewModifier {
    let view: ReaderView
    func body(content: Content) -> some View { view.applyDialogs(view.applyChrome(content)) }
}

/// The anchor is a fractional sentence index while animating. Every row uses the same
/// interpolated origin, so the column moves together even when sentence heights differ.
struct SentenceColumn: Layout {
    var position: CGFloat
    var readingOffset: CGFloat
    let firstIndex: Int
    let spacing: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(position, readingOffset) }
        set { position = newValue.first; readingOffset = newValue.second }
    }

    struct Cache {
        var width: CGFloat?
        var heights: [CGFloat] = []
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    static let clearTop: CGFloat = 0.24
    static let clearBand: CGFloat = 0.52

    static func anchorTop(height: CGFloat, in screen: CGFloat) -> CGFloat {
        height > screen * clearBand ? screen * clearTop : (screen - height) / 2
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        guard !subviews.isEmpty else { return }
        if cache.width != bounds.width || cache.heights.count != subviews.count {
            let width = ProposedViewSize(width: bounds.width, height: nil)
            cache.heights = subviews.map { $0.sizeThatFits(width).height }
            cache.width = bounds.width
        }
        let cursor = min(max(position - CGFloat(firstIndex), 0), CGFloat(subviews.count - 1))
        let start = Int(cursor)
        let end = min(start + 1, subviews.count - 1)
        let heights = cache.heights
        let before = heights.prefix(start).reduce(0) { $0 + $1 + spacing }
        let initial = Self.anchorTop(height: heights[start], in: bounds.height) - before
        let final = Self.anchorTop(height: heights[end], in: bounds.height) - before - heights[start] - spacing
        var y = bounds.minY + initial + (final - initial) * (cursor - CGFloat(start)) + readingOffset
        for i in subviews.indices {
            subviews[i].place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: heights[i]))
            y += heights[i] + spacing
        }
    }
}

final class RowHeights {
    private var chapter: Int?
    private var heights: [Int: CGFloat] = [:]

    func value(_ index: Int, chapter: Int) -> CGFloat? {
        self.chapter == chapter ? heights[index] : nil
    }

    func record(_ height: CGFloat, at index: Int, chapter: Int) {
        if self.chapter != chapter {
            self.chapter = chapter
            heights.removeAll()
        }
        heights[index] = height
    }
}

/// Moves the same set of rows during a swipe and during playback.
private struct TheaterColumn: View, Equatable {
    let units: [BookListener.Unit]
    let chapterIndex: Int
    let currentIndex: Int
    let range: Range<Int>
    let reduceMotion: Bool
    let heights: RowHeights
    let position: CGFloat
    let readingOffset: CGFloat
    let progress: ListenProgress
    let accent: Color
    let type: TheaterType
    let annotations: [Int: [String: String]]
    /// While listening, the current sentence fills in word by word with the voice.
    let karaoke: Bool
    let animatesWords: Bool
    let onTap: () -> Void
    let onLookup: (String, BookListener.Unit) -> Void

    static func == (a: TheaterColumn, b: TheaterColumn) -> Bool {
        a.chapterIndex == b.chapterIndex && a.currentIndex == b.currentIndex
            && a.range == b.range && a.reduceMotion == b.reduceMotion && a.units.count == b.units.count
            && a.position == b.position && a.readingOffset == b.readingOffset
            && a.animatesWords == b.animatesWords && a.accent == b.accent && a.type == b.type
            && a.annotations == b.annotations && a.karaoke == b.karaoke
    }

    var body: some View {
        SentenceColumn(position: position, readingOffset: readingOffset, firstIndex: range.lowerBound, spacing: type.rowSpacing) {
            ForEach(Array(range), id: \.self) { index in
                let unit = units[index]
                TheaterSentenceRow(
                    unit: unit, distance: index - currentIndex, reduceMotion: reduceMotion,
                    progress: progress, accent: accent, type: type,
                    annotations: unit.ids.reduce(into: [:]) { result, id in
                        result.merge(annotations[id] ?? [:]) { _, new in new }
                    },
                    karaoke: karaoke, animatesWords: animatesWords, onLookup: onLookup
                )
                    .equatable()
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { heights.record($0, at: index, chapter: chapterIndex) }
                    .id("\(chapterIndex)-\(unit.ids.first ?? 0)")
                    .contentShape(Rectangle())
                    // Any tap that isn't on a word shows or hides the buttons.
                    .onTapGesture { onTap() }
            }
        }
    }
}

/// Keep text shaping and annotation preparation independent of changes in scroll position.
private struct TheaterSentenceRow: View, Equatable {
    let unit: BookListener.Unit
    let distance: Int
    let reduceMotion: Bool
    let progress: ListenProgress
    let accent: Color
    let type: TheaterType
    let annotations: [String: String]
    let karaoke: Bool
    let animatesWords: Bool
    let onLookup: (String, BookListener.Unit) -> Void

    private static let ink = Color(white: 0.93)
    private var focusAnimation: Animation? { reduceMotion ? nil : .easeOut(duration: 0.23) }

    static func == (a: TheaterSentenceRow, b: TheaterSentenceRow) -> Bool {
        a.unit.ids == b.unit.ids && a.unit.text == b.unit.text && a.distance == b.distance
            && a.reduceMotion == b.reduceMotion && a.progress === b.progress
            && a.accent == b.accent && a.type == b.type && a.annotations == b.annotations
            && (a.distance != 0 || (a.karaoke == b.karaoke && a.animatesWords == b.animatesWords))
    }

    var body: some View {
        let away = abs(distance)
        let text = unit.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return Group {
            if away == 0 {
                KaraokeText(text: Self.words(text), progress: progress, accent: accent, captionSize: type.caption,
                            annotations: annotations, karaoke: karaoke, animatesWords: animatesWords)
                    .transition(.identity)
            } else {
                Text(AttributedString(text))
                    .transition(.identity)
            }
        }
            .tint(Self.ink)
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == "readle-word", let word = url.host(percentEncoded: false)?.removingPercentEncoding, !word.isEmpty else { return .discarded }
                onLookup(word, unit)
                return .handled
            })
            // One weight for every line: changing weight re-wraps the text and ghosts mid-animation.
            .font(.system(size: type.size, weight: .medium, design: .serif))
            .lineSpacing(type.lineSpacing)
            .padding(.top, annotations.isEmpty ? 0 : type.glossRoom)
            .fixedSize(horizontal: false, vertical: true) // always the full sentence, never "..."
            .foregroundStyle(Self.ink.opacity(away == 0 ? 1 : max(0.16, 0.46 - Double(away) * 0.1)))
            .blur(radius: away == 0 ? 0 : min(9, 2.5 + Double(away) * 1.6))
            .scaleEffect(away == 0 || reduceMotion ? 1 : 0.95, anchor: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(focusAnimation, value: distance)
            .accessibilityHidden(away != 0)
    }

    /// The sentence as words, each a link that SwiftUI renders as plain text (same line breaks
    /// as the blurred rows, so nothing re-wraps when a sentence comes into focus). Cached: the
    /// tokenizer is far too slow to run on every frame.
    nonisolated(unsafe) private static var wordCache: [String: AttributedString] = [:]
    private static func words(_ text: String) -> AttributedString {
        if let cached = wordCache[text] { return cached }
        var result = AttributedString()
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var cursor = text.startIndex
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            if cursor < range.lowerBound { result += AttributedString(String(text[cursor..<range.lowerBound])) }
            let word = String(text[range])
            var piece = AttributedString(word)
            // Every word is a link of its own (so it can be looked up, and so it stays its own run
            // for the word-by-word highlight).
            if let encoded = word.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
               let url = URL(string: "readle-word://\(encoded)") {
                piece.link = url
            }
            result += piece
            cursor = range.upperBound
            return true
        }
        if cursor < text.endIndex { result += AttributedString(String(text[cursor...])) }
        if wordCache.count > 300 { wordCache.removeAll() }
        wordCache[text] = result
        return result
    }
}

/// The current sentence fills in on the player's sample clock.
private struct KaraokeText: View {
    @ObservedObject var progress: ListenProgress
    let accent: Color
    let captionSize: CGFloat
    let karaoke: Bool
    let animatesWords: Bool
    private let plain: String
    private let marked: Text
    private let unitStarts: [Int]
    private let labels: [String?]

    init(text: AttributedString, progress: ListenProgress, accent: Color, captionSize: CGFloat,
         annotations: [String: String], karaoke: Bool, animatesWords: Bool) {
        self.progress = progress
        self.accent = accent
        self.captionSize = captionSize
        self.karaoke = karaoke
        self.animatesWords = animatesWords
        let plain = String(text.characters)
        let words = WordTiming.words(plain)
        self.plain = plain
        marked = Self.markedText(text, words: words)
        unitStarts = words.flatMap { WordTiming.units(in: $0) }.map { $0.startIndex.utf16Offset(in: plain) }
        labels = words.map { word in
            annotations.first { $0.key.localizedCaseInsensitiveCompare(String(word)) == .orderedSame }?.value
        }
    }

    var body: some View {
        let timing = progress.timing?.text == plain ? progress.timing : nil
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !animatesWords || timing == nil)) { _ in
            marked.textRenderer(KaraokeRenderer(lit: karaoke ? lit(timing: timing) : nil,
                                                 accent: accent, captionSize: captionSize, annotations: labels))
        }
    }

    // Attach the ordinal to the displayed word itself. Layout indices can change with Unicode
    // characters, ligatures, and wrapping, so they are not offsets into the source sentence.
    private static func markedText(_ text: AttributedString, words: [Substring]) -> Text {
        var cursor = text.startIndex
        func segment(_ range: Range<AttributedString.Index>, index: Int) -> Text {
            Text(AttributedString(text[range])).customAttribute(KaraokeWord(index: index))
        }
        var marked = Text(verbatim: "")
        var index = 0
        for (wordIndex, word) in words.enumerated() {
            for unit in WordTiming.units(in: word) {
                guard let start = AttributedString.Index(unit.startIndex, within: text),
                      let end = AttributedString.Index(unit.endIndex, within: text),
                      cursor <= start else { return Text(text) }
                if cursor < start {
                    marked = Text("\(marked)\(segment(cursor..<start, index: max(0, index - 1)))")
                }
                marked = Text("\(marked)\(segment(start..<end, index: index).customAttribute(AnnotationWord(index: wordIndex)))")
                cursor = end
                index += 1
            }
        }
        if cursor < text.endIndex {
            marked = Text("\(marked)\(segment(cursor..<text.endIndex, index: max(0, index - 1)))")
        }
        return marked
    }

    private func lit(timing: WordTiming?) -> Double {
        if let timing, let time = progress.clock?() { return timing.lit(at: time) }
        guard let range = progress.spokenRange else { return 0 }
        return Double(unitStarts.prefix { $0 < NSMaxRange(range) }.count)
    }
}

private struct AnnotationWord: TextAttribute { let index: Int }

private struct KaraokeWord: TextAttribute {
    let index: Int
}

private struct KaraokeRenderer: TextRenderer {
    let lit: Double?
    let accent: Color
    let captionSize: CGFloat
    let annotations: [String?]

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        var drawnAnnotations: Set<Int> = []
        for line in layout {
            var annotationBounds: [Int: CGRect] = [:]
            for run in line {
                let word = run[KaraokeWord.self]
                var layer = context
                if let lit {
                    if let word, Double(word.index) < lit { layer.addFilter(.colorMultiply(accent)) }
                    else { layer.opacity = 0.4 }
                }
                layer.draw(run)
                if let annotation = run[AnnotationWord.self], annotations.indices.contains(annotation.index),
                   annotations[annotation.index] != nil, !drawnAnnotations.contains(annotation.index) {
                    let bounds = run.typographicBounds.rect
                    annotationBounds[annotation.index] = annotationBounds[annotation.index]?.union(bounds) ?? bounds
                }
            }
            for (index, bounds) in annotationBounds {
                guard let label = annotations[index] else { continue }
                let caption = context.resolve(Text(label).font(.system(size: captionSize, weight: .medium)).foregroundStyle(accent))
                context.draw(caption, at: CGPoint(x: bounds.midX, y: bounds.minY - captionSize * 2 / 3), anchor: .center)
                drawnAnnotations.insert(index)
            }
        }
    }
}

/// The main colour of a book's cover, made bright enough to glow on theater mode's black.
enum CoverAccent {
    static let fallback = Color(white: 0.95) // if a cover can't be read

    static func load(_ url: URL) async -> Color {
        await Task.detached(priority: .utility) { () -> Color in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return fallback }
            return accent(of: image) ?? fallback
        }.value
    }

    /// The colour that covers most of the cover, light and grey tones included (a white cover
    /// gives white). Kept recognisable but bright enough to show on black.
    nonisolated static func accent(of image: CGImage) -> Color? {
        let size = 32
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        guard let context = CGContext(data: &pixels, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        // Count pixels in coarse colour bins (6 levels per channel) and keep the biggest.
        var count = [Int](repeating: 0, count: 216)
        var sum = [SIMD3<Double>](repeating: .zero, count: 216)
        for i in 0..<(size * size) {
            let r = Double(pixels[i * 4]) / 255, g = Double(pixels[i * 4 + 1]) / 255, b = Double(pixels[i * 4 + 2]) / 255
            let bin = min(Int(r * 6), 5) * 36 + min(Int(g * 6), 5) * 6 + min(Int(b * 6), 5)
            count[bin] += 1
            sum[bin] += [r, g, b]
        }
        guard let best = count.indices.max(by: { count[$0] < count[$1] }), count[best] > 0 else { return nil }
        let mean = sum[best] / Double(count[best])
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        UIColor(red: mean.x, green: mean.y, blue: mean.z, alpha: 1).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        // A dark main colour (deep green, navy, black) is lifted so it still glows on black.
        return Color(hue: hue, saturation: min(saturation, 0.85), brightness: max(brightness, 0.82))
    }
}

/// Which mode each book was last left in (the reader or theater mode), kept across launches so the
/// book opens the same way next time.
enum ReadingModeMemory {
    private static func key(_ id: UUID) -> String { "readingMode.theater." + id.uuidString }
    static func theater(_ id: UUID) -> Bool { UserDefaults.standard.bool(forKey: key(id)) }
    static func set(theater: Bool, for id: UUID) { UserDefaults.standard.set(theater, forKey: key(id)) }
}

struct BookAudioOfferRequest: Identifiable {
    enum Start { case reader, theater }
    let id = UUID()
    let start: Start
}

/// A calm suggestion, the first time you listen to a book: download its whole audio first, and
/// how that works (in the background, from where you are, paused if you leave the app).
private struct BookAudioOfferSheet: View {
    let download: () -> Void
    let listen: () -> Void
    @State private var height: CGFloat = 420

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Palette.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text("先下载全书音频？")
                    .font(.system(.title3, design: .serif).weight(.semibold))
                Text("下载好整本书的朗读后，从任意一句开始听都会更顺畅。")
                    .foregroundStyle(Palette.muted)
            }
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle").foregroundStyle(Palette.muted).accessibilityHidden(true)
                Text("下载会从你正在读的地方开始，在后台进行。进度稍微超过你读到的位置后，就可以边下载边听。下载时请留在句读院，离开应用会暂停下载。")
                    .font(.footnote)
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .background(Palette.muted.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(spacing: 10) {
                Button(action: download) {
                    Text("下载全书音频")
                        .font(.headline)
                        .foregroundStyle(Palette.paper)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Palette.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .accessibilityIdentifier("bookAudioOfferDownload")
                Button(action: listen) {
                    Text("先直接听")
                        .font(.body.weight(.medium))
                        .foregroundStyle(Palette.accent)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .accessibilityIdentifier("bookAudioOfferListen")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 12)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height = $0 }
        .presentationDetents([.height(height)])
        .presentationDragIndicator(.visible)
    }
}
