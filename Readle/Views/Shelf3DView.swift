import SwiftUI
import RealityKit
import UIKit
import CoreImage
import Combine
import Metal
import NaturalLanguage

/// One book as the 3D shelf needs it.
struct ShelfBook: Equatable {
    let id: UUID
    let title: String
    let author: String
    let sentences: Int
    let coverURL: URL
}

/// The spiral bookcase, in an industrial room: microcement wall, charcoal stone floor, matte black
/// powder-coated steel steps winding around a black steel core, books standing cover-out.
/// Turning the tower is the only gesture: spin it and you travel up or down the spiral, the book
/// in front stepping forward. Only the books near you exist in 3D, so it can hold any number.
struct Shelf3DView: View {
    @ObservedObject var scene: ShelfScene
    let books: [ShelfBook]
    let coverVersion: Int
    let onOpen: (UUID, OpenedPage) -> Void
    let onMenu: (UUID) -> Void
    /// The 3D view's own size, edge to edge (it runs under the bars and safe areas).
    var onResize: (CGSize) -> Void = { _ in }
    /// True while the screen has a new size and the shelf is being set up again for it: the old
    /// drawing would be the wrong shape, so only the room's backdrop shows meanwhile.
    var resizing = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.roomy) private var roomy
    @State private var scrubbing = false
    /// The whole screen's height, edge to edge.
    @State private var roomHeight: CGFloat = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            ShelfARView(scene: scene)
                .ignoresSafeArea()
                .onGeometryChange(for: CGSize.self, of: { $0.size }) { size in
                    roomHeight = size.height
                    onResize(size)
                }
                .opacity(resizing ? 0 : 1)
                .animation(.easeOut(duration: 0.35), value: resizing)
                .background(night ? Color(white: 0.3) : Color(red: 0.9, green: 0.88, blue: 0.84)) // the room's own backdrop
                .overlay(alignment: .trailing) { if books.count > 24 { scrubber.padding(.trailing, roomy ? 18 : 10).padding(.bottom, 80) } }
                // A gentle darkening behind the header and the title, so text stays easy to read.
                // Each is a share of the screen's height (the lower one reaching up past the title),
                // and as an overlay it can never make the shelf taller than a short landscape screen.
                .overlay {
                    VStack(spacing: 0) {
                        LinearGradient(stops: [.init(color: veil.opacity(night ? 0.55 : 0.32), location: 0), .init(color: veil.opacity(night ? 0.35 : 0.12), location: 0.55), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom)
                            .frame(height: min(night ? 190 : 140, roomHeight * 0.3))
                        Spacer(minLength: 0)
                        LinearGradient(colors: [.clear, veil.opacity(night ? 0.5 : 0.22)], startPoint: .top, endPoint: .bottom)
                            .frame(height: roomHeight * (night ? 0.39 : 0.3))
                    }
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .opacity(scene.bookOpen ? 0 : 1) // the dive starts from the book alone
                    .animation(.easeOut(duration: 0.25), value: scene.bookOpen)
                }
                .accessibilityHidden(true)
        }
        // The title sits just under the front book (which the camera keeps a little below centre).
        .overlay(alignment: .top) {
            GeometryReader { geo in
                card
                    .opacity(scene.bookOpen ? 0 : 1) // out of the way while a book is open
                    .animation(.easeOut(duration: 0.25), value: scene.bookOpen)
                    .frame(maxWidth: roomy ? 560 : .infinity)
                    .frame(height: roomy ? 120 : 104, alignment: .top)
                    .padding(.horizontal, 28)
                    .frame(width: geo.size.width)
                    .offset(y: geo.size.height * 0.705)
            }
            .ignoresSafeArea()
        }
        .onAppear { sync() }
        .onChange(of: books) { _, _ in sync() }
        .onChange(of: coverVersion) { _, _ in sync() }
        .onChange(of: colorScheme) { _, _ in sync() }
        .onChange(of: reduceMotion) { _, _ in sync() }
        .onChange(of: scene.bookOpen) { _, open in if !open { sync() } }
        .sensoryFeedback(.selection, trigger: scene.focus) { _, _ in !scrubbing }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(focused.map { "螺旋书架，第 \(scene.focus + 1) 本，共 \(books.count) 本：\($0.title)" } ?? "螺旋书架")
        .accessibilityHint("上下轻扫切换书本，连按两下打开")
        .accessibilityAddTraits(.isButton)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: scene.focus(on: scene.focus + 1)
            case .decrement: scene.focus(on: scene.focus - 1)
            @unknown default: break
            }
        }
        .accessibilityAction { scene.openFocused() }
    }

    private var night: Bool { colorScheme == .dark }
    /// What the edges fade into, so the header and title stay readable: shade at night, light by day.
    private var veil: Color { night ? .black : Color(red: 0.97, green: 0.955, blue: 0.93) }

    private var focused: ShelfBook? { books.indices.contains(scene.focus) ? books[scene.focus] : nil }

    private var card: some View {
        ZStack(alignment: .top) {
            if let book = focused {
                VStack(spacing: roomy ? 7 : 5) {
                    Text(book.title)
                        .font(.system(roomy ? .title2 : .title3, design: .serif).weight(.semibold))
                        .foregroundStyle(night ? .white : Palette.ink)
                        .multilineTextAlignment(.center).lineLimit(2)
                        .shadow(color: night ? .black.opacity(0.35) : .clear, radius: 6, y: 1)
                    if !book.author.isEmpty {
                        Text(book.author).font(roomy ? .subheadline : .footnote).foregroundStyle(Palette.muted).lineLimit(1)
                    }
                }
                .id(book.id)
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 6)), removal: .opacity))
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.2), value: scene.focus)
    }

    /// A slim track on the right: drag it to fly through a large library.
    private var scrubber: some View {
        GeometryReader { geo in
            let track = geo.size.height
            let progress = books.count > 1 ? CGFloat(scene.focus) / CGFloat(books.count - 1) : 0
            // The first books sit at the bottom of the spiral, so the track runs bottom to top.
            let thumbY = (1 - progress) * (track - 28) + 14
            ZStack(alignment: .top) {
                Capsule().fill(Palette.ink.opacity(0.18)).frame(width: 3)
                Capsule().fill(Palette.ink.opacity(scrubbing ? 0.9 : 0.6))
                    .frame(width: scrubbing ? 7 : 5, height: 28)
                    .position(x: geo.size.width / 2, y: thumbY)
            }
            .frame(width: 30)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    scrubbing = true
                    let fraction = 1 - min(max((value.location.y - 14) / max(track - 28, 1), 0), 1)
                    scene.scrub(to: Double(fraction))
                }
                .onEnded { _ in scrubbing = false; scene.endScrub() })
            .animation(.easeOut(duration: 0.15), value: scrubbing)
        }
        .frame(width: 30, height: min(roomy ? 360 : 230, max(roomHeight * 0.45, 120)))
        .hoverEffect(.highlight)
    }

    private func sync() {
        scene.onOpen = onOpen
        scene.onMenu = onMenu
        // Never rebuild the room under an open book: it would cut its opening or return short.
        // It catches up as soon as the book is back on the shelf.
        guard !scene.bookOpen else { return }
        scene.update(books: books, coverVersion: coverVersion, dark: colorScheme == .dark, reduceMotion: reduceMotion)
    }
}

private struct ShelfARView: UIViewRepresentable {
    let scene: ShelfScene
    func makeUIView(context: Context) -> ARView { scene.arView }
    func updateUIView(_ view: ARView, context: Context) {}
}

// MARK: - Scene

/// A value that follows its target like a critically damped spring: quick, never wobbly.
private struct Spring {
    var value: Float
    var target: Float
    var velocity: Float = 0
    var stiffness: Float
    init(_ value: Float, stiffness: Float) { self.value = value; self.target = value; self.stiffness = stiffness }
    mutating func step(_ dt: Float) {
        let damping = 2 * stiffness.squareRoot()
        velocity += (stiffness * (target - value) - damping * velocity) * dt
        value += velocity * dt
    }
    mutating func jump(to value: Float) { self.value = value; target = value; velocity = 0 }
}

@MainActor
final class ShelfScene: NSObject, ObservableObject, UIGestureRecognizerDelegate {
    @Published private(set) var focus = 0
    /// True from the moment a book starts opening until it starts closing again.
    @Published private(set) var bookOpen = false
    /// Opens a book, once its cover has swung open: where its page is on screen, and a still.
    var onOpen: ((UUID, OpenedPage) -> Void)?
    /// The page you stopped at in a book, for the inside of the opened book.
    var pageContent: ((UUID) async -> InsidePage?)?
    /// Sets up the reader out of sight while the opened book is still, so the dive can show it.
    var prepareReader: ((UUID) async -> Void)?
    var onMenu: ((UUID) -> Void)?

    let arView: ARView
    private let world = AnchorEntity(world: .zero)
    private let camera = PerspectiveCamera()
    private let spiral = Entity()       // turns; carries the core, steps and books
    private let core = ModelEntity()
    private let cap = ModelEntity()
    private let ground = Entity()       // floor, wall, stand and the shadow under it
    private var live: [Int: Item] = [:]
    private var steps: [Int: ModelEntity] = [:]
    private var books: [ShelfBook] = []
    private var textures: [UUID: (art: CGImage, texture: TextureResource?)] = [:]
    private var textureOrder: [UUID] = []
    private var coverVersion = -1
    private var dark: Bool?
    private var reduceMotion = false
    private var room: ShelfArt.Room?
    // A soft room light, and one gentle light from above on the book on display, nothing else.
    private let window = DirectionalLight()
    private let fill = DirectionalLight()
    private let wash = SpotLight()
    private var stepMesh: MeshResource?
    private var updates: (any Combine.Cancellable)?
    private let thump = UIImpactFeedbackGenerator(style: .soft)

    // Motion.
    private var spin = Spring(0, stiffness: 70)       // tower angle; turning it is climbing it
    private var distance = Spring(ShelfScene.viewDistance, stiffness: 40)
    private var spinning = false
    private var scrubbing = false
    private var panStart: Float = 0
    private var clock: Float = 0
    private var opening: (index: Int, start: Float)?

    // The spiral (meters).
    static let perTurn = 10
    static let pitch: Float = 0.27                    // rise per full turn
    static let coreRadius: Float = 0.075
    static let bookRadius: Float = 0.262              // where covers stand
    static let stepRadius: Float = 0.2
    static let stepDepth: Float = 0.25
    static let baseY: Float = 0.13                    // first step, above the stand
    static let fov: Float = 30
    static let viewDistance: Float = 1.6           // close enough that the front cover reads easily
    static let wallZ: Float = -0.8
    static let lean: Float = 9 * .pi / 180
    static var slot: Float { 2 * .pi / Float(perTurn) }
    static var rise: Float { pitch / Float(perTurn) }

    @MainActor private final class Item {
        let index: Int
        let root = Entity()   // place on the spiral and the step-forward
        let body = Entity()   // lean, pivoting at the bottom edge
        let width: Float
        let height: Float
        let depth: Float
        init(index: Int, width: Float, height: Float, depth: Float) {
            self.index = index; self.width = width; self.height = height; self.depth = depth
        }
    }

    /// `size`: the size the 3D view will have on screen, when known (a scene set up again after a
    /// rotation or resize starts drawing at exactly that size).
    init(size: CGSize = .zero) {
        arView = ARView(frame: CGRect(origin: .zero, size: size), cameraMode: .nonAR, automaticallyConfigureSession: false)
        super.init()
        arView.renderOptions = [.disableMotionBlur, .disableDepthOfField, .disableCameraGrain, .disableFaceMesh,
                                .disablePersonOcclusion, .disableGroundingShadows, .disableAREnvironmentLighting]
        arView.environment.background = .color(.white)
        arView.scene.addAnchor(world)
        camera.camera.fieldOfViewInDegrees = Self.fov
        camera.camera.near = 0.04
        world.addChild(camera)
        world.addChild(ground)
        spiral.addChild(core)
        spiral.addChild(cap)
        world.addChild(spiral)

        // No cast shadows from the room light: the only light you notice is the one above the book.
        window.look(at: [0, 0.3, 0], from: [-2.4, 1.9, 0.9], relativeTo: nil)
        world.addChild(window)
        fill.look(at: .zero, from: [1.6, 0.6, 2], relativeTo: nil)
        world.addChild(fill)
        wash.light.color = UIColor(red: 1, green: 0.86, blue: 0.68, alpha: 1)
        wash.light.innerAngleInDegrees = 6     // a very soft edge: a wash, never a visible circle
        wash.light.outerAngleInDegrees = 60    // narrow enough to stay on the one book
        wash.light.attenuationRadius = 0.55
        spiral.addChild(wash)
        if let studio = ShelfArt.studio(), let resource = try? EnvironmentResource(equirectangular: studio) {
            arView.environment.lighting.resource = resource
            arView.environment.lighting.intensityExponent = 0.3
        }

        let pan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
        pan.delegate = self
        let tap = UITapGestureRecognizer(target: self, action: #selector(tap(_:)))
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(hold(_:)))
        hold.minimumPressDuration = 0.45
        // iPad with a trackpad or mouse: two-finger scrolling or the wheel turns the tower, and a
        // secondary click opens the same menu as a long press.
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scroll(_:)))
        scroll.allowedScrollTypesMask = .all
        scroll.allowedTouchTypes = []
        let menu = UITapGestureRecognizer(target: self, action: #selector(secondaryClick(_:)))
        menu.buttonMaskRequired = .secondary
        menu.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        tap.require(toFail: menu)
        for recognizer in [pan, tap, hold, scroll, menu] as [UIGestureRecognizer] { arView.addGestureRecognizer(recognizer) }

        updates = arView.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            MainActor.assumeIsolated { self?.step(Float(min(event.deltaTime, 1.0 / 30))) }
        }
    }

    // MARK: Content

    /// RealityKit keeps drawing at the size its view first had, so when the iPad rotates or is
    /// resized the shelf is set up again at the new size; it starts on the book that was in front,
    /// without the opening spin.
    func resume(at id: UUID?) { resumeID = id; resuming = true }
    private var resumeID: UUID?
    private var resuming = false

    func update(books new: [ShelfBook], coverVersion version: Int, dark isDark: Bool, reduceMotion motion: Bool) {
        reduceMotion = motion
        var rebuild = false
        if dark != isDark {
            dark = isDark
            // Day: a solid-wood room in soft daylight. Night: the concrete room from the photo.
            arView.environment.background = .color(isDark ? UIColor(white: 0.3, alpha: 1) : UIColor(red: 0.9, green: 0.88, blue: 0.84, alpha: 1))
            window.light.color = isDark ? UIColor(red: 0.92, green: 0.95, blue: 1, alpha: 1) : UIColor(red: 1, green: 0.96, blue: 0.9, alpha: 1)
            window.light.intensity = isDark ? 1900 : 1400
            fill.light.intensity = isDark ? 300 : 380
            arView.environment.lighting.intensityExponent = isDark ? 0.15 : 0.5 // bright enough that the shelf reads white
            room = ShelfArt.Room(dark: isDark, wall: isDark ? nil : Self.fineDay?.wall, floor: isDark ? nil : Self.fineDay?.floor)
            if !isDark && Self.fineDay == nil { refineDayRoom() }
            rebuild = true
        }
        if version != coverVersion { textures = [:]; textureOrder = []; coverVersion = version; rebuild = true }
        guard rebuild || new != books else { return }
        let keep = books.indices.contains(focus) ? books[focus].id : nil
        let first = books.isEmpty
        books = new
        live.values.forEach { $0.root.removeFromParent() }; live = [:]
        steps.values.forEach { $0.removeFromParent() }; steps = [:]
        buildCore()
        buildRoom()

        let index = (keep ?? resumeID).flatMap { id in new.firstIndex { $0.id == id } } ?? min(focus, max(0, new.count - 1))
        let skipEntrance = resuming
        resumeID = nil; resuming = false
        if first && !reduceMotion && !skipEntrance {
            // Entrance: the spiral unwinds down to the first book.
            spin.jump(to: -Float(min(10, max(new.count - 1, 0))) * Self.slot)
            spin.target = -Float(index) * Self.slot
        } else {
            spin.jump(to: -Float(index) * Self.slot)
        }
        focus = index
    }

    func focus(on index: Int) {
        guard !books.isEmpty, opening == nil else { return }
        let index = min(max(index, 0), books.count - 1)
        spin.target = -Float(index) * Self.slot
        if reduceMotion { spin.jump(to: spin.target) }
    }

    /// Keyboard: one book along from wherever the tower is heading (so a held arrow key keeps going).
    func turn(by delta: Int) {
        guard !books.isEmpty, opening == nil else { return }
        let heading = Int((-spin.target / Self.slot).rounded())
        focus(on: heading + delta)
    }

    /// Search: spin to a book from wherever you are. Far away, it starts a few books short and
    /// glides the last stretch, so it reads as a spin rather than a cut.
    func jump(to index: Int) {
        guard books.indices.contains(index), opening == nil else { return }
        let target = Float(index)
        if abs(target + spin.value / Self.slot) > 8 {
            let start = min(max(target + (target > -spin.value / Self.slot ? -6 : 6), 0), Float(books.count - 1))
            spin.jump(to: -start * Self.slot)
        }
        spin.target = -target * Self.slot
    }

    /// Opening a book: the cover swings open where the book stands, on the page you stopped at; a
    /// beat later the view eases in on one word of the page, gathering speed until you dive through
    /// it into the reader.
    func openFocused() {
        guard books.indices.contains(focus), opening == nil, closing == nil, let item = live[focus] else { return }
        let index = focus, id = books[focus].id, book = books[index]
        spin.jump(to: -Float(index) * Self.slot)
        thump.impactOccurred(intensity: 0.55)
        bookOpen = true
        retreat = nil
        let size = CGSize(width: BookPage.width, height: BookPage.width * CGFloat(item.height / item.width))
        let started = CACurrentMediaTime(), settled = started + Double(Self.openDuration)
        // With Reduce Motion the book is simply open.
        let instant = reduceMotion
        opening = (index, instant ? clock - 10 : clock)
        Task { @MainActor [weak self] in
            let wait = settled - CACurrentMediaTime()
            if wait > 0 { try? await Task.sleep(for: .milliseconds(Int(wait * 1000))) }
            guard let self, self.opening?.index == index else { return }
            self.landing.impactOccurred(intensity: 0.4) // the cover settles open
        }
        Task { @MainActor [weak self] in
            // The page is printed while the cover is still swinging open.
            let content = await self?.pageContent?(id)
            guard let self, self.opening?.index == index else { return }
            let mark = await self.addInsidePage(to: item, book: book, content: content, size: size)
            guard self.opening?.index == index else { return }
            guard !instant, let mark, let page = item.body.findEntity(named: "titlepage") else {
                // Nothing to dive into (or Reduce Motion): once it's open, straight to the page.
                let wait = instant ? 0 : settled - CACurrentMediaTime()
                if wait > 0 { try? await Task.sleep(for: .milliseconds(Int(wait * 1000))) }
                guard self.opening?.index == index else { return }
                self.onOpen?(id, OpenedPage(snapshot: nil, screen: self.arView.bounds.size))
                return
            }
            // Once the cover lands, the reader is set up out of sight (the scene is still meanwhile);
            // after a short beat the camera eases in.
            let wait = settled - CACurrentMediaTime()
            if wait > 0 { try? await Task.sleep(for: .milliseconds(Int(wait * 1000))) }
            guard self.opening?.index == index else { return }
            await self.prepareReader?(id)
            guard self.opening?.index == index else { return }
            let beat = settled + 0.2 - CACurrentMediaTime()
            if beat > 0 { try? await Task.sleep(for: .milliseconds(Int(beat * 1000))) }
            guard self.opening?.index == index else { return }
            self.beginDive(index: index, id: id, page: page, item: item, mark: mark, size: size)
        }
    }

    /// The push into a word: where it's heading (on the page, so it follows the book), how far it
    /// has to go for one letter stroke to fill the screen, and when the entrance takes over.
    private struct Dive {
        let index: Int
        let id: UUID
        let point: SIMD3<Float>        // in the page's own space
        let corners: [SIMD3<Float>]    // the word's box, in the page's space
        let curve: DiveCurve
        let holes: CGImage?
        let fromDirection: SIMD3<Float>
        let fromTarget: SIMD3<Float>
        let distance: Float
        let handoff: Double            // zoom (log) at which the entrance takes over
        var handedOff = false
        /// Leaving: the same dive played backwards from `start`, over `duration`.
        var back: (start: CFTimeInterval, duration: Double)?
        var closed = false
    }

    /// Back out of the reader: the dive plays backwards, quick out of the letter and settling
    /// gently onto the shelf; the cover closes as the camera lands.
    func returnFromDive(start: CFTimeInterval, duration: Double) {
        guard var dive else { return }
        DiveHaptics.shared.stop()
        dive.back = (start, duration)
        self.dive = dive
    }
    private var dive: Dive?
    /// Back out to the shelf after a book closes: from where the camera was, over this long.
    private var retreat: (start: CFTimeInterval, eye: SIMD3<Float>, target: SIMD3<Float>)?
    private var lastEye: SIMD3<Float> = .zero
    private var lastTarget: SIMD3<Float> = .zero
    static let diveDuration = 2.0

    private func beginDive(index: Int, id: UUID, page: Entity, item: Item, mark: BookPage.Mark, size: CGSize) {
        let pw = item.width - 0.008, ph = item.height - 0.01
        func local(_ p: CGPoint) -> SIMD3<Float> { [Float(p.x / size.width - 0.5) * pw, Float(0.5 - p.y / size.height) * ph, 0] }
        let point = local(mark.point)
        let r = mark.word
        let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                       CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)].map(local)
        let world = page.convert(position: point, to: nil)
        // How big one design point looks from here, so the dive ends with one stroke filling the screen.
        let aside = page.convert(position: local(CGPoint(x: mark.point.x + 10, y: mark.point.y)), to: nil)
        guard let a = arView.project(world), let b = arView.project(aside) else {
            onOpen?(id, OpenedPage(snapshot: nil, screen: arView.bounds.size)); return
        }
        let perDesign = max(hypot(b.x - a.x, b.y - a.y) / 10, 0.05)
        let screen = arView.bounds.size
        var total = log(Double(hypot(screen.width, screen.height) * 1.25 / max(mark.depth * perDesign, 0.02)))
        let handoff = min(total * DiveCurve.shape(0.5), log(2.5)) // early enough for the letters to open in time
        total = max(total, handoff + log(80.0))
        dive = Dive(index: index, id: id, point: point, corners: corners,
                    curve: DiveCurve(start: CACurrentMediaTime(), duration: Self.diveDuration, total: total), holes: mark.holes,
                    fromDirection: simd_normalize(lastEye - world), fromTarget: lastTarget,
                    distance: simd_length(lastEye - world), handoff: handoff)
        if let dive { DiveHaptics.shared.play(dive.curve) }
    }

    /// The camera along the dive this frame, and whether the entrance should take over now.
    private func diveCamera(_ now: CFTimeInterval) -> (eye: SIMD3<Float>, target: SIMD3<Float>, handoff: Double?)? {
        guard var dive, let page = live[dive.index]?.body.findEntity(named: "titlepage") else { return nil }
        let through: Bool, zoom: Double, x: Float
        if let back = dive.back {
            // Leaving: the dive backwards. The still covers it until it is back at the handoff.
            let u = (now - back.start) / back.duration
            if u >= 0.75 && !dive.closed {
                dive.closed = true
                self.dive = dive
                closeBook(dive.index)
            }
            if u >= 1 { self.dive = nil; return nil } // exactly where the shelf view was
            let progress = min(max(1 - u, 0), 1)
            through = false
            zoom = min(dive.curve.total * DiveCurve.shape(progress), dive.handoff)
            x = Float(progress)
        } else {
            through = now >= dive.curve.end
            // Once through, rest where the still was taken (hidden behind the reader), ready to pull back.
            zoom = through ? dive.handoff : dive.curve.zoomLog(at: now)
            x = Float((now - dive.curve.start) / dive.curve.duration)
        }
        let p = page.convert(position: dive.point, to: nil)
        let n = simd_normalize(page.convert(direction: [0, 0, 1], to: nil))
        // First turn to face the page square on, centred on the word; from then on, straight in.
        let s = min(max(x / 0.38, 0), 1), a = s * s * (3 - 2 * s)
        let direction = simd_normalize(simd_mix(dive.fromDirection, n, SIMD3(repeating: through ? 1 : a)))
        let d = max(dive.distance / Float(exp(zoom)), 0.06)
        var handoff: Double?
        if dive.back == nil && !dive.handedOff && !through && zoom >= dive.handoff {
            dive.handedOff = true
            self.dive = dive
            handoff = zoom
        }
        return (p + direction * d, simd_mix(dive.fromTarget, p, SIMD3(repeating: through ? 1 : a)), handoff)
    }

    /// The entrance takes over: a still of this very frame, where the word and the point are on it,
    /// and the rest of the dive.
    private func handOff(zoom: Double) {
        guard let dive, let page = live[dive.index]?.body.findEntity(named: "titlepage") else { return }
        let anchor = arView.project(page.convert(position: dive.point, to: nil)) ?? CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        var word = CGRect.null
        for corner in dive.corners {
            if let q = arView.project(page.convert(position: corner, to: nil)) { word = word.union(CGRect(origin: q, size: .zero)) }
        }
        var curve = dive.curve
        curve.handoff = zoom
        let screen = arView.bounds.size, index = dive.index, id = dive.id, holes = dive.holes
        Task { @MainActor [weak self] in
            let still = await self?.snapshot()
            guard let self, self.dive?.index == index else { return }
            self.onOpen?(id, OpenedPage(snapshot: still, screen: screen, word: word.isNull ? nil : word, holes: holes, anchor: anchor, dive: curve))
        }
    }

    /// A still of the scene exactly as it is on screen.
    private func snapshot() async -> UIImage? {
        await withCheckedContinuation { continuation in
            arView.snapshot(saveToHDR: false) { image in continuation.resume(returning: image) }
        }
    }

    static let openDuration: Float = 0.85
    static let closeDuration: Float = 0.6
    private var closing: (index: Int, start: Float)?
    private let landing = UIImpactFeedbackGenerator(style: .light)

    /// The inside of the book: the page you stopped at (or, failing that, a title page), and where
    /// on it the word to dive through is printed.
    private func addInsidePage(to item: Item, book: ShelfBook, content: InsidePage?, size: CGSize) async -> BookPage.Mark? {
        guard item.body.findEntity(named: "titlepage") == nil else { return nil }
        var image: CGImage?, mark: BookPage.Mark?
        if let content {
            // Printed sharp enough to stay crisp as the camera closes in.
            let printed = await Task.detached(priority: .userInitiated) {
                PrintedPage(image: BookPage.render(content, size: size, scale: 6), mark: BookPage.mark(content, size: size))
            }.value
            image = printed.image; mark = printed.mark
        } else {
            let renderer = ImageRenderer(content: TitlePage(title: book.title, author: book.author).frame(width: size.width, height: size.height))
            renderer.scale = 3
            image = renderer.cgImage
        }
        var material = UnlitMaterial()
        if let image, let texture = try? await TextureResource(image: image, options: .init(semantic: .color)) {
            material.color = .init(tint: UIColor(white: 0.97, alpha: 1), texture: .init(texture))
        } else {
            material.color = .init(tint: UIColor(white: 0.95, alpha: 1))
        }
        guard item.body.findEntity(named: "titlepage") == nil else { return nil }
        let page = ModelEntity(mesh: .generatePlane(width: item.width - 0.008, height: item.height - 0.01), materials: [material])
        page.name = "titlepage"
        page.position = [0.002, item.height / 2, item.depth / 2 - 0.0024 + 0.0006]
        item.body.addChild(page)
        return mark
    }

    private struct PrintedPage: @unchecked Sendable {
        let image: CGImage?
        let mark: BookPage.Mark?
    }

    /// Back from the reader: the camera pulls back out, the cover closes and the book goes back on its step.
    func settle() {
        guard let opening else { return }
        if dive?.back != nil { return } // already on its way back; it closes the book as it lands
        DiveHaptics.shared.stop()
        if dive != nil { retreat = (CACurrentMediaTime(), lastEye, lastTarget) }
        dive = nil
        closeBook(opening.index)
    }

    private func closeBook(_ index: Int) {
        opening = nil
        bookOpen = false
        closing = (index, clock)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(Self.closeDuration * 1000) + 50))
            guard let self, self.closing?.index == index else { return }
            self.closing = nil
            self.landing.impactOccurred(intensity: 0.35) // the cover closes: lighter than going in
            self.live[index]?.body.findEntity(named: "titlepage")?.removeFromParent()
        }
    }

    func scrub(to fraction: Double) {
        guard books.count > 1, opening == nil else { return }
        scrubbing = true
        let position = Float(fraction) * Float(books.count - 1)
        spin.jump(to: -position * Self.slot)
    }

    func endScrub() {
        scrubbing = false
        spin.target = -(-spin.value / Self.slot).rounded() * Self.slot
    }

    // MARK: Building

    private var topY: Float { Self.baseY + Float(max(books.count - 1, 0)) * Self.rise + 0.25 }

    private func buildCore() {
        guard let room else { return }
        // The core only needs to be as tall as what the camera can see; it travels with you.
        let height = min(topY - Self.baseY + 0.12, 2.6)
        core.model = ModelComponent(mesh: .generateCylinder(height: height, radius: Self.coreRadius), materials: [room.powder])
        cap.model = ModelComponent(mesh: .generateCylinder(height: 0.012, radius: Self.coreRadius + 0.03), materials: [room.powder])
        // True wedges: each step is a slice of a ring, so neighbours meet edge to edge, never overlap.
        stepMesh = ShelfArt.wedge(inner: Self.coreRadius - 0.002, outer: Self.stepRadius + Self.stepDepth / 2,
                                  angle: Self.slot, thickness: 0.007)
    }

    /// The room: a microcement wall tall enough for the whole spiral, a stone floor, the stand.
    /// The day room's limestone and oak at twice the detail (they fill the screen up close), made
    /// off the main thread and swapped in when ready.
    private static var fineDay: (wall: CGImage, floor: CGImage)?
    private struct FineImages: @unchecked Sendable { let wall: CGImage?; let floor: CGImage? }
    private func refineDayRoom() {
        Task { @MainActor [weak self] in
            let fine = await Task.detached(priority: .utility) {
                FineImages(wall: Textures.limestone(scale: 2), floor: Textures.oakFloor(scale: 2))
            }.value
            guard let wall = fine.wall, let floor = fine.floor else { return }
            Self.fineDay = (wall, floor)
            guard let self, self.dark == false else { return }
            self.room = ShelfArt.Room(dark: false, wall: wall, floor: floor)
            self.buildRoom()
        }
    }

    private func buildRoom() {
        guard let room else { return }
        ground.children.removeAll()
        let wallHeight = max(5, topY + 2.5)
        let wall = ModelEntity(mesh: .generatePlane(width: 9, height: wallHeight), materials: [room.wall(width: 9, height: wallHeight)])
        wall.position = [0, wallHeight / 2, Self.wallZ]
        let floor = ModelEntity(mesh: .generatePlane(width: 12, depth: 12), materials: [room.floor(size: 12)])
        floor.position = [0, 0, Self.wallZ + 6]
        let pole = ModelEntity(mesh: .generateCylinder(height: Self.baseY - 0.012, radius: 0.026), materials: [room.powder])
        pole.position = [0, 0.012 + (Self.baseY - 0.012) / 2, 0]
        let base = ModelEntity(mesh: .generateCylinder(height: 0.012, radius: 0.15), materials: [room.powder])
        base.position = [0, 0.007, 0]
        let under = ShelfArt.shadowPlane(.round, width: 0.56, height: 0.56, opacity: 0.55)
        under.position = [0, 0.0015, 0]
        for entity in [wall, floor, pole, base, under] { ground.addChild(entity) }
    }

    private func cover(for index: Int) -> (art: CGImage, texture: TextureResource?) {
        let book = books[index]
        if let cached = textures[book.id] { return cached }
        let art = ShelfArt.cover(for: book)
        let texture = try? TextureResource(image: art, options: .init(semantic: .color, mipmapsMode: .allocateAndGenerateAll))
        textures[book.id] = (art, texture)
        textureOrder.append(book.id)
        if textureOrder.count > 140 { textures[textureOrder.removeFirst()] = nil } // keep memory flat
        return (art, texture)
    }

    private func makeItem(_ index: Int) -> Item {
        let book = books[index]
        let (art, texture) = cover(for: index)
        let aspect = Float(art.width) / Float(max(art.height, 1))
        let width = min(max(0.2 * aspect, 0.118), 0.148)
        let height = min(max(width / max(aspect, 0.01), 0.14), 0.205)
        let depth = 0.013 + 0.022 * min(1, Float(book.sentences) / 9000)
        let item = Item(index: index, width: width, height: height, depth: depth)
        item.root.name = "book-\(index)"
        ShelfArt.buildBook(into: item.body, art: art, texture: texture, width: width, height: height, depth: depth)
        item.root.addChild(item.body)
        item.root.components.set(CollisionComponent(shapes: [.generateBox(width: width, height: height, depth: depth).offsetBy(translation: [0, height / 2, 0])]))
        spiral.addChild(item.root)
        return item
    }

    private func makeStep(_ index: Int) -> ModelEntity? {
        guard let stepMesh, let room else { return nil }
        let step = ModelEntity(mesh: stepMesh, materials: [room.powder])
        let a = Float(index) * Self.slot
        step.position = [0, Self.baseY + Float(index) * Self.rise, 0]
        step.orientation = simd_quatf(angle: a, axis: [0, 1, 0])
        spiral.addChild(step)
        return step
    }

    // MARK: Motion

    private func step(_ dt: Float) {
        clock += dt
        let last = Float(max(books.count - 1, 0))
        if !spinning && !scrubbing { spin.step(reduceMotion ? dt * 3 : dt) }
        spiral.orientation = simd_quatf(angle: spin.value, axis: [0, 1, 0])

        // Position along the spiral (in books) and the one in front.
        let position = -spin.value / Self.slot
        let nearest = Int(min(max(position.rounded(), 0), last))
        if nearest != focus, opening == nil, !books.isEmpty { focus = nearest }

        // Camera follows the height you're at; it glides closer while a book opens.
        let lookY = Self.baseY + min(max(position, -0.5), last + 0.5) * Self.rise + 0.105
        // While a book opens the view holds still; then it closes in on a word (see `diveCamera`).
        distance.step(dt)
        var eye: SIMD3<Float> = [0, lookY + distance.value * 0.17, distance.value]
        var target: SIMD3<Float> = [0, lookY - 0.04, 0]
        var handoff: Double?
        let now = CACurrentMediaTime()
        if let path = diveCamera(now) {
            eye = path.eye; target = path.target; handoff = path.handoff
        } else if let retreat {
            let x = Float(min(max((now - retreat.start) / 0.85, 0), 1))
            let u = x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
            eye = simd_mix(retreat.eye, eye, SIMD3(repeating: u))
            target = simd_mix(retreat.target, target, SIMD3(repeating: u))
            if x >= 1 { self.retreat = nil }
        }
        camera.look(at: target, from: eye, relativeTo: nil)
        lastEye = eye; lastTarget = target
        if let handoff { handOff(zoom: handoff) }
        // A soft light from above on the book on display only, hung under the step one turn up so
        // that step doesn't shade the cover. Gentle: easy to look at, never glaring.
        let brightness: Float = dark == true ? 950 : 800
        do {
            let index = Int(min(max(position.rounded(), 0), last))
            let a = Float(index) * Self.slot
            let out = SIMD3<Float>(sin(a), 0, cos(a))
            let y = Self.baseY + Float(index) * Self.rise
            // The front book steps forward, so its light moves out with it to keep lighting the cover.
            let away = abs(Float(index) - position)
            let near = max(0, 1 - away), forward = near * near * (3 - 2 * near)
            let edge = Self.stepRadius + Self.stepDepth / 2 - 0.01
            wash.look(at: out * (Self.bookRadius + 0.055 * forward) + [0, y + 0.17, 0],
                      from: out * (edge + 0.12 * forward) + [0, y + Self.pitch - 0.012, 0], relativeTo: spiral)
            wash.light.intensity = books.isEmpty ? 0 : brightness * max(0.3, 1 - away * 0.7)
        }

        // The core rides along so it always fills the view; the lid waits at the very top.
        let coreHeight = min(topY - Self.baseY + 0.12, 2.6)
        let coreMid = min(max(lookY, Self.baseY - 0.06 + coreHeight / 2), topY + 0.06 - coreHeight / 2)
        core.position = [0, coreMid, 0]
        cap.position = [0, topY + 0.068, 0]

        // Build only what's near: about two turns above and below.
        let reach = Float(Self.perTurn) * 2.3
        let lo = max(0, Int(position - reach)), hi = Int(min(last, position + reach))
        for (index, item) in live where index < lo - 4 || index > hi + 4 { item.root.removeFromParent(); live[index] = nil }
        for (index, step) in steps where index < lo - 4 || index > hi + 6 { step.removeFromParent(); steps[index] = nil }
        if !books.isEmpty && lo <= hi {
            for index in lo...min(hi + 2, books.count + 1) where steps[index] == nil { steps[index] = makeStep(index) }
            // New books arrive a few per frame, nearest first, so turning never stutters.
            let missing = (lo...hi).filter { live[$0] == nil }.sorted { abs(Float($0) - position) < abs(Float($1) - position) }
            for index in missing.prefix(scrubbing ? 6 : 3) { live[index] = makeItem(index) }
        }
        for item in live.values { place(item, position: position) }
    }

    private func place(_ item: Item, position: Float) {
        let a = Float(item.index) * Self.slot
        let near = max(0, 1 - abs(Float(item.index) - position))
        let f = near * near * (3 - 2 * near) // how "in front" this book is
        let normal = SIMD3<Float>(sin(a), 0, cos(a))
        // Opening: the cover swings open on its spine right where the book stands; closing plays it backwards.
        var swing: Float = 0
        if let opening, opening.index == item.index {
            swing = easeInOut((clock - opening.start) / Self.openDuration)
        } else if let closing, closing.index == item.index {
            swing = easeInOut(1 - min(max((clock - closing.start) / Self.closeDuration, 0), 1))
        }
        // The front book steps forward and grows a little, but always stands wholly on its board:
        // its front corners stay a finger's width inside the board's curved edge.
        let grown = 1 + 0.2 * f, edge = Self.stepRadius + Self.stepDepth / 2, half = item.width * grown / 2
        let inside = (edge * edge - half * half).squareRoot() - 0.012 - item.depth * grown / 2
        let out = min(Self.bookRadius - item.depth / 2 + 0.055 * f, inside)
        item.root.position = normal * out + [0, Self.baseY + Float(item.index) * Self.rise, 0]
        item.body.findEntity(named: "hinge")?.orientation = simd_quatf(angle: -2.9 * swing, axis: [0, 1, 0])
        item.root.orientation = simd_quatf(angle: a, axis: [0, 1, 0])
        item.root.scale = .init(repeating: grown)
        item.body.orientation = simd_quatf(angle: -Self.lean * (1 - f), axis: [1, 0, 0])
    }

    private func easeOut(_ t: Float) -> Float { let x = min(max(t, 0), 1); return 1 - pow(1 - x, 3) }
    private func easeInOut(_ t: Float) -> Float { let x = min(max(t, 0), 1); return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }

    // MARK: Gestures

    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard let pan = recognizer as? UIPanGestureRecognizer else { return true }
        let v = pan.velocity(in: arView)
        return abs(v.x) >= abs(v.y)
    }

    @objc private func pan(_ recognizer: UIPanGestureRecognizer) {
        guard opening == nil, !books.isEmpty else { return }
        let width = Float(max(arView.bounds.width, 1))
        let perPoint = .pi * 1.1 / width           // about a half turn across the screen
        let lowest = -Float(books.count - 1) * Self.slot
        switch recognizer.state {
        case .began:
            spinning = true; panStart = spin.value; spin.velocity = 0
        case .changed:
            let raw = panStart + Float(recognizer.translation(in: arView).x) * perPoint
            // Gentle resistance past the first and last book.
            spin.value = raw > 0 ? raw * 0.3 : raw < lowest ? lowest + (raw - lowest) * 0.3 : raw
            spin.target = spin.value
        default:
            spinning = false
            let velocity = Float(recognizer.velocity(in: arView).x) * perPoint
            spin.velocity = velocity
            let projected = spin.value + velocity * 0.3
            let index = min(max((-projected / Self.slot).rounded(), 0), Float(books.count - 1))
            spin.target = -index * Self.slot
        }
    }

    /// Trackpad and mouse wheel: whichever direction you scroll more, a quarter as far per point
    /// as a finger drag, settling on the nearest book when you stop.
    @objc private func scroll(_ recognizer: UIPanGestureRecognizer) {
        guard opening == nil, !books.isEmpty else { return }
        let width = Float(max(arView.bounds.width, 1))
        let perPoint = .pi * 1.1 / width
        let lowest = -Float(books.count - 1) * Self.slot
        let moved = recognizer.translation(in: arView), speed = recognizer.velocity(in: arView)
        let along = abs(moved.x) >= abs(moved.y) ? Float(moved.x) : Float(moved.y)
        switch recognizer.state {
        case .began:
            spinning = true; panStart = spin.value; spin.velocity = 0
        case .changed:
            spin.value = min(max(panStart + along * perPoint, lowest), 0)
            spin.target = spin.value
        default:
            spinning = false
            let velocity = (abs(speed.x) >= abs(speed.y) ? Float(speed.x) : Float(speed.y)) * perPoint
            let projected = spin.value + velocity * 0.15
            let index = min(max((-projected / Self.slot).rounded(), 0), Float(books.count - 1))
            spin.target = -index * Self.slot
        }
    }

    @objc private func secondaryClick(_ recognizer: UITapGestureRecognizer) {
        guard opening == nil, let index = index(at: recognizer.location(in: arView)), books.indices.contains(index) else { return }
        focus(on: index)
        onMenu?(books[index].id)
    }

    private func index(at point: CGPoint) -> Int? {
        var entity = arView.entity(at: point)
        while let current = entity {
            if current.name.hasPrefix("book-"), let index = Int(current.name.dropFirst(5)) { return index }
            entity = current.parent
        }
        return nil
    }

    @objc private func tap(_ recognizer: UITapGestureRecognizer) {
        guard opening == nil, let index = index(at: recognizer.location(in: arView)), books.indices.contains(index) else { return }
        if index == focus && abs(spin.value - spin.target) < 0.02 { openFocused() } else { focus(on: index) }
    }

    @objc private func hold(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, let index = index(at: recognizer.location(in: arView)), books.indices.contains(index) else { return }
        thump.impactOccurred(intensity: 0.5)
        focus(on: index)
        onMenu?(books[index].id)
    }
}

// MARK: - Art: books, room, shadows, light

enum ShelfArt {
    enum Shadow { case round, long }

    /// Boards, spine and pages, with the cover printed on the front board. Pivot: bottom center.
    @MainActor static func buildBook(into body: Entity, art: CGImage, texture: TextureResource?, width: Float, height: Float, depth: Float) {
        let board: Float = 0.0024
        let boardColor = averageColor(art)
        var boardMaterial = PhysicallyBasedMaterial()
        boardMaterial.baseColor = .init(tint: boardColor)
        boardMaterial.roughness = 0.62
        var pagesMaterial = PhysicallyBasedMaterial()
        pagesMaterial.baseColor = .init(tint: UIColor(white: 0.94, alpha: 1))
        pagesMaterial.roughness = 0.9
        var coverMaterial = PhysicallyBasedMaterial()
        if let texture {
            coverMaterial.baseColor = .init(tint: .white, texture: .init(texture))
        } else {
            coverMaterial.baseColor = .init(tint: boardColor)
        }
        coverMaterial.roughness = 0.5
        coverMaterial.clearcoat = 0.14
        coverMaterial.clearcoatRoughness = 0.3

        // The front board hangs on a hinge at the spine, so the book can really be opened.
        let hinge = Entity()
        hinge.name = "hinge"
        hinge.position = [-width / 2, height / 2, depth / 2 - board / 2]
        let front = ModelEntity(mesh: .generateBox(width: width, height: height, depth: board, cornerRadius: 0.0009), materials: [boardMaterial])
        front.position = [width / 2, 0, 0]
        let cover = ModelEntity(mesh: .generatePlane(width: width - 0.0004, height: height - 0.0004, cornerRadius: 0.0008), materials: [coverMaterial])
        cover.position = [0, 0, board / 2 + 0.0002]
        front.addChild(cover)
        hinge.addChild(front)
        let back = ModelEntity(mesh: .generateBox(width: width, height: height, depth: board, cornerRadius: 0.0009), materials: [boardMaterial])
        back.position = [0, height / 2, -depth / 2 + board / 2]
        let spine = ModelEntity(mesh: .generateBox(width: board, height: height, depth: depth, cornerRadius: 0.0009), materials: [boardMaterial])
        spine.position = [-width / 2 + board / 2, height / 2, 0]
        let pages = ModelEntity(mesh: .generateBox(width: width - 0.006, height: height - 0.007, depth: depth - board * 2), materials: [pagesMaterial])
        pages.position = [0.002, height / 2, 0]
        for part in [hinge, back, spine, pages] { body.addChild(part) }
    }

    /// The book's own cover, or a quiet typographic one for books without.
    @MainActor static func cover(for book: ShelfBook) -> CGImage {
        if let source = CGImageSourceCreateWithURL(book.coverURL as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) { return image }
        let renderer = ImageRenderer(content: GeneratedCover(title: book.title, author: book.author, seed: book.id))
        renderer.scale = 2
        return renderer.cgImage ?? blank
    }

    private static let blank: CGImage = {
        let context = CGContext(data: nil, width: 4, height: 6, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(UIColor(white: 0.85, alpha: 1).cgColor); context.fill(CGRect(x: 0, y: 0, width: 4, height: 6))
        return context.makeImage()!
    }()

    static func averageColor(_ image: CGImage) -> UIColor {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return .gray }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return UIColor(red: CGFloat(pixel[0]) / 255 * 0.82, green: CGFloat(pixel[1]) / 255 * 0.82, blue: CGFloat(pixel[2]) / 255 * 0.82, alpha: 1)
    }

    /// A slice of a ring (a spiral-staircase step), top face at y = 0, centred on +z.
    @MainActor static func wedge(inner r0: Float, outer r1: Float, angle: Float, thickness t: Float, segments n: Int = 14) -> MeshResource? {
        var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], indices: [UInt32] = []
        func point(_ r: Float, _ a: Float, _ y: Float) -> SIMD3<Float> { [sin(a) * r, y, cos(a) * r] }
        func quad(_ corners: [SIMD3<Float>], _ faceNormals: [SIMD3<Float>]) {
            let base = UInt32(positions.count)
            positions += corners; normals += faceNormals
            indices += [base, base + 1, base + 2, base, base + 2, base + 3]
        }
        let up = SIMD3<Float>(0, 1, 0)
        for k in 0..<n {
            let a0 = -angle / 2 + angle * Float(k) / Float(n), a1 = -angle / 2 + angle * Float(k + 1) / Float(n)
            let out0 = SIMD3<Float>(sin(a0), 0, cos(a0)), out1 = SIMD3<Float>(sin(a1), 0, cos(a1))
            quad([point(r0, a0, 0), point(r1, a0, 0), point(r1, a1, 0), point(r0, a1, 0)], Array(repeating: up, count: 4))
            quad([point(r0, a1, -t), point(r1, a1, -t), point(r1, a0, -t), point(r0, a0, -t)], Array(repeating: -up, count: 4))
            quad([point(r1, a0, 0), point(r1, a0, -t), point(r1, a1, -t), point(r1, a1, 0)], [out0, out0, out1, out1])
            quad([point(r0, a1, 0), point(r0, a1, -t), point(r0, a0, -t), point(r0, a0, 0)], [-out1, -out1, -out0, -out0])
        }
        let lo = -angle / 2, hi = angle / 2
        let startNormal = -SIMD3<Float>(cos(lo), 0, -sin(lo)), endNormal = SIMD3<Float>(cos(hi), 0, -sin(hi))
        quad([point(r0, lo, 0), point(r0, lo, -t), point(r1, lo, -t), point(r1, lo, 0)], Array(repeating: startNormal, count: 4))
        quad([point(r1, hi, 0), point(r1, hi, -t), point(r0, hi, -t), point(r0, hi, 0)], Array(repeating: endNormal, count: 4))
        var descriptor = MeshDescriptor(name: "step")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.primitives = .triangles(indices)
        return try? MeshResource.generate(from: [descriptor])
    }

    /// The room's materials, all generated in code (seamless, so they tile without visible joins).
    @MainActor struct Room {
        let dark: Bool
        let blackSteel: PhysicallyBasedMaterial
        let powder: PhysicallyBasedMaterial
        private let plaster: TextureResource?
        private let stone: TextureResource?

        /// `wall`/`floor`: finer versions of the day room's surfaces, made in the background.
        init(dark: Bool, wall: CGImage? = nil, floor: CGImage? = nil) {
            self.dark = dark
            // Light: honed limestone walls over a solid oak floor. Dark: concrete and stone.
            plaster = Room.texture(dark ? Textures.microcement() : wall ?? Textures.limestone())
            stone = Room.texture(dark ? Textures.stoneTiles() : floor ?? Textures.oakFloor())
            var black = PhysicallyBasedMaterial()
            black.baseColor = .init(tint: UIColor(white: 0.16, alpha: 1))
            black.metallic = 0.85
            black.roughness = 0.42
            blackSteel = black
            // Powder-coated steel with a faint satin sheen: cream by day, matte black by night.
            var coat = PhysicallyBasedMaterial()
            coat.baseColor = .init(tint: dark ? UIColor(white: 0.07, alpha: 1) : UIColor(white: 0.985, alpha: 1))
            coat.metallic = dark ? 0.25 : 0.08
            coat.roughness = 0.55
            coat.clearcoat = 0.35
            coat.clearcoatRoughness = 0.35
            powder = coat
        }

        /// Limestone by day; the photo's grey microcement at night.
        func wall(width: Float, height: Float) -> PhysicallyBasedMaterial {
            var material = PhysicallyBasedMaterial()
            material.baseColor = .init(tint: .white, texture: Room.repeating(plaster))
            let tile: Float = dark ? 2.2 : 2.4 // the limestone slabs repeat every 2.4 m
            material.textureCoordinateTransform = .init(offset: .zero, scale: [width / tile, height / tile], rotation: 0)
            material.roughness = dark ? 0.92 : 0.84 // honed, not polished
            return material
        }

        /// Oiled solid oak by day, a soft satin; charcoal stone at night.
        func floor(size: Float) -> PhysicallyBasedMaterial {
            var material = PhysicallyBasedMaterial()
            material.baseColor = .init(tint: .white, texture: Room.repeating(stone))
            material.textureCoordinateTransform = .init(offset: .zero, scale: [size / 2.4, size / 2.4], rotation: 0)
            material.roughness = dark ? 0.62 : 0.52
            material.clearcoat = dark ? 0.18 : 0.22
            material.clearcoatRoughness = dark ? 0.4 : 0.38
            return material
        }

        private static func texture(_ image: CGImage?) -> TextureResource? {
            guard let image else { return nil }
            return try? TextureResource(image: image, options: .init(semantic: .color, mipmapsMode: .allocateAndGenerateAll))
        }

        private static func repeating(_ texture: TextureResource?) -> MaterialParameters.Texture? {
            guard let texture else { return nil }
            var parameter = MaterialParameters.Texture(texture)
            let sampler = MTLSamplerDescriptor()
            sampler.sAddressMode = .repeat; sampler.tAddressMode = .repeat
            sampler.minFilter = .linear; sampler.magFilter = .linear; sampler.mipFilter = .linear
            sampler.maxAnisotropy = 8
            parameter.sampler = .init(sampler)
            return parameter
        }
    }

    @MainActor static func steelMaterial(dark: Bool) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: UIColor(white: dark ? 0.5 : 0.86, alpha: 1))
        material.metallic = 1.0
        material.roughness = 0.24
        return material
    }

    /// A soft, blurred dark shape on the floor: far gentler than a real shadow map.
    @MainActor static func shadowPlane(_ kind: Shadow, width: Float, height: Float, opacity: Float) -> ModelEntity {
        var material = UnlitMaterial(applyPostProcessToneMap: false)
        material.color = .init(tint: .black)
        if let texture = shadowTexture(kind) {
            material.blending = .transparent(opacity: .init(scale: opacity, texture: .init(texture)))
        }
        let plane = ModelEntity(mesh: .generatePlane(width: width, depth: height), materials: [material])
        return plane
    }

    @MainActor private static var shadowCache: [Shadow: TextureResource] = [:]
    @MainActor private static func shadowTexture(_ kind: Shadow) -> TextureResource? {
        if let cached = shadowCache[kind] { return cached }
        let image: CGImage?
        switch kind {
        case .round:
            // A radial falloff: dark under the base, fading to nothing.
            let gradient = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: 128, y: 128), "inputRadius0": 52, "inputRadius1": 124,
                "inputColor0": CIColor.white, "inputColor1": CIColor.black])?.outputImage?.cropped(to: CGRect(x: 0, y: 0, width: 256, height: 256))
            image = gradient.flatMap { CIContext().createCGImage($0, from: $0.extent) }
        case .long:
            let size = CGRect(x: 0, y: 0, width: 128, height: 256)
            let shape = CIImage(color: .white).cropped(to: CGRect(x: 40, y: 40, width: 48, height: 196))
            let blurred = shape.composited(over: CIImage(color: .black).cropped(to: size))
                .clampedToExtent().applyingGaussianBlur(sigma: 22).cropped(to: size)
            image = CIContext().createCGImage(blurred, from: blurred.extent)
        }
        guard let image, let texture = try? TextureResource(image: image, options: .init(semantic: .raw)) else { return nil }
        shadowCache[kind] = texture
        return texture
    }

    /// A tiny studio: bright soft light above, neutral sides, darker floor.
    static func studio() -> CGImage? {
        let width = 256, height = 128
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let colors = [UIColor(white: 0.25, alpha: 1).cgColor, UIColor(white: 0.6, alpha: 1).cgColor, UIColor(white: 0.97, alpha: 1).cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.5, 1]) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: height), options: [])
        }
        context.setFillColor(UIColor.white.cgColor)
        context.fillEllipse(in: CGRect(x: 80, y: 86, width: 70, height: 30))
        return context.makeImage()
    }
}

/// A typographic cover in black, grey and white, varied per book.
private struct GeneratedCover: View {
    let title: String
    let author: String
    let seed: UUID

    private var style: (paper: Color, ink: Color, rule: Color) {
        // Mostly deep cloth tones (they read as real books), a few bone-white.
        let styles: [(Color, Color, Color)] = [
            (Color(white: 0.09), Color(white: 0.96), Color(white: 0.5)),
            (Color(white: 0.2), Color(white: 0.95), Color(white: 0.55)),
            (Color(red: 0.16, green: 0.155, blue: 0.15), Color(white: 0.93), Color(white: 0.5)),
            (Color(white: 0.97), Color(white: 0.08), Color(white: 0.6)),
            (Color(white: 0.34), Color(white: 0.97), Color(white: 0.7)),
        ]
        let value = seed.uuid.0 ^ seed.uuid.5 ^ seed.uuid.11
        return styles[Int(value) % styles.count]
    }

    var body: some View {
        let style = style
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(style.rule).frame(width: 36, height: 2)
            Spacer().frame(height: 26)
            Text(title)
                .font(.system(size: 34, weight: .semibold, design: .serif))
                .foregroundStyle(style.ink)
                .lineLimit(5).minimumScaleFactor(0.5)
            Spacer()
            if !author.isEmpty {
                Text(author.uppercased())
                    .font(.system(size: 13, weight: .medium)).tracking(2)
                    .foregroundStyle(style.ink.opacity(0.7)).lineLimit(2)
            }
            Rectangle().fill(style.rule).frame(height: 1).padding(.top, 14)
            Text("句读院").font(.system(size: 10, weight: .semibold)).tracking(3)
                .foregroundStyle(style.ink.opacity(0.45)).padding(.top, 10)
        }
        .padding(30)
        .frame(width: 300, height: 450, alignment: .topLeading)
        .background(style.paper)
    }
}

// MARK: - Procedural textures

/// Seamless textures drawn in code: every pattern repeats exactly at the image edges.
private enum Textures {
    /// Smooth random values on a wrapping grid: periodic "value noise".
    private struct Noise {
        let cells: Int
        let rows: Int
        let values: [Float]
        init(cells: Int, rows: Int? = nil, seed: UInt64) {
            self.cells = cells
            self.rows = rows ?? cells
            var state = seed
            values = (0..<(cells * (rows ?? cells))).map { _ in
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return Float(state >> 40) / Float(1 << 24)
            }
        }
        func at(_ u: Float, _ v: Float) -> Float {
            let x = u * Float(cells), y = v * Float(rows)
            let x0 = Int(floor(x)), y0 = Int(floor(y))
            let fx = x - Float(x0), fy = y - Float(y0)
            let sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy)
            func value(_ i: Int, _ j: Int) -> Float { values[((j % rows + rows) % rows) * cells + (i % cells + cells) % cells] }
            let a = value(x0, y0) + (value(x0 + 1, y0) - value(x0, y0)) * sx
            let b = value(x0, y0 + 1) + (value(x0 + 1, y0 + 1) - value(x0, y0 + 1)) * sx
            return a + (b - a) * sy
        }
    }

    private static func fbm(_ layers: [Noise], _ u: Float, _ v: Float) -> Float {
        var sum: Float = 0, weight: Float = 0, amplitude: Float = 1
        for layer in layers { sum += layer.at(u, v) * amplitude; weight += amplitude; amplitude *= 0.55 }
        return sum / weight
    }

    private static func draw(size: Int, _ pixel: (Int, Int) -> SIMD3<Float>) -> CGImage? {
        var bytes = [UInt8](repeating: 255, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let c = simd_clamp(pixel(x, y), .zero, .one) * 255
                let o = (y * size + x) * 4
                bytes[o] = UInt8(c.x); bytes[o + 1] = UInt8(c.y); bytes[o + 2] = UInt8(c.z)
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private static func grain(_ x: Int, _ y: Int, _ seed: UInt32) -> Float {
        var h = UInt32(truncatingIfNeeded: x) &* 374761393 &+ UInt32(truncatingIfNeeded: y) &* 668265263 &+ seed
        h = (h ^ (h >> 13)) &* 1274126177
        return Float(h & 0xFFFF) / 65535
    }

    /// Hand-troweled microcement: soft cloudy patches over a fine grain, warm grey.
    static func microcement() -> CGImage? {
        let size = 384
        let layers = [Noise(cells: 3, seed: 11), Noise(cells: 6, seed: 12), Noise(cells: 12, seed: 13), Noise(cells: 24, seed: 14), Noise(cells: 48, seed: 15)]
        let base = SIMD3<Float>(0.585, 0.565, 0.545)
        return draw(size: size) { x, y in
            let u = Float(x) / Float(size), v = Float(y) / Float(size)
            let cloud = fbm(layers, u, v)
            let shade = 0.84 + 0.3 * cloud + (grain(x, y, 7) - 0.5) * 0.045
            return base * shade
        }
    }

    /// Honed limestone: big slabs in a running bond with hairline joints; a warm cream ground with
    /// soft clouding, faint bedding lines drifting across it, and the odd fleck of shell.
    nonisolated static func limestone(scale k: Int = 1) -> CGImage? {
        let size = 512 * k, slabW = 256 * k, slabH = 128 * k // 1.2 × 0.6 m slabs on a 2.4 m tile
        let cloud = [Noise(cells: 4, seed: 81), Noise(cells: 8, seed: 82), Noise(cells: 16, seed: 83), Noise(cells: 32, seed: 84), Noise(cells: 64, seed: 85)]
        let bedding = Noise(cells: 3, rows: 72, seed: 86)
        let drift = Noise(cells: 5, rows: 3, seed: 87)
        let pits = Noise(cells: 420, rows: 300, seed: 88)
        let base = SIMD3<Float>(0.87, 0.825, 0.745)
        return draw(size: size) { x, y in
            let row = y / slabH, py = y % slabH
            let shifted = x + (row % 2) * slabW / 2
            let px = shifted % slabW
            let slab = (shifted / slabW) % (size / slabW) + row * 7
            let u = Float(x) / Float(size), v = Float(y) / Float(size)
            // Each slab cut from a slightly different part of the block.
            let tone: Float = 0.955 + Float((slab * 53) % 7) * 0.013
            let mottling: Float = 0.9 + 0.2 * fbm(cloud, u, v)
            let bed: Float = 1 + (bedding.at(u, v + 0.03 * drift.at(u, v)) - 0.5) * 0.07
            // The stone's fine porosity: small soft pores, slightly shaded.
            let pore = pits.at(u, v)
            let porous: Float = pore > 0.8 ? 1 - (pore - 0.8) * 0.25 : 1
            var color: SIMD3<Float> = base * (tone * mottling * bed * porous)
            color.z *= 0.975 + Float((slab * 17) % 5) * 0.012  // some slabs a touch cooler
            // Shell fragments: rare, tiny, barely there; a few a shade deeper, a few paler.
            let fleck = grain(x, y, 91), rare = 0.0012 / Float(k * k)
            if fleck > 1 - rare { color *= 0.93 } else if fleck < rare * 1.5 { color = color * 0.7 + SIMD3<Float>(repeating: 0.29) }
            color *= 1 + (grain(x, y, 92) - 0.5) * 0.04   // a fine sandy tooth
            // Tight joints, with an eased arris beside them.
            let joint = min(py, px)
            if joint < k { color *= 0.62 } else if joint < 2 * k { color *= 0.9 }
            return color
        }
    }

    /// Wide-plank solid oak, oiled: long boards with staggered ends, each with its own shade and
    /// grain — growth rings that wander along the board, fine open pores, a softly eased edge.
    nonisolated static func oakFloor(scale k: Int = 1) -> CGImage? {
        let size = 576 * k, plank = 48 * k                 // 12 boards across 2.4 m, 20 cm wide
        let lengths = [576, 288, 576, 192, 576, 288, 192, 576, 288, 576, 192, 576].map { $0 * k } // all divide the tile
        let pores = [Noise(cells: 5, rows: 240, seed: 71), Noise(cells: 11, rows: 480, seed: 72), Noise(cells: 23, rows: 900, seed: 75)]
        let flow = Noise(cells: 6, rows: 12, seed: 73)
        let figure = Noise(cells: 3, rows: 24, seed: 74)
        let base = SIMD3<Float>(0.67, 0.49, 0.33)
        return draw(size: size) { x, y in
            let row = y / plank, py = y % plank
            let length = lengths[row % lengths.count], offset = (row * 211 * k) % length
            let along = (x + offset) % length
            let board = ((x + offset) / length) % (size / length) + row * 13
            let r = Float((board * 7919 + 17) % 1000) / 1000 // this board's own character
            let u = Float(x) / Float(size), v = Float(y) / Float(size)
            // Growth rings run along the board and wander gently across it.
            let across = Float(py) / Float(plank)
            let wander: Float = (flow.at(u + r, v) - 0.5) * 2.2 + sin((u * 2 + r) * .pi * 2) * 0.3
            let ring = across * (2.5 + 3 * r) + wander
            let band = abs(ring - floor(ring) - 0.5) * 2
            let strength: Float = 0.6 + 0.8 * figure.at(u * 2 + r, v)
            let late: Float = pow(band, 4) * strength       // the darker latewood line, stronger in places
            let pore: Float = fbm(pores, u + r * 0.37, v)
            let fibre: Float = grain(x / (7 * k) + board * 31, y, 43) // short streaks along the grain
            var shade: Float = (0.86 + 0.24 * r) * (1 - 0.17 * late) * (0.84 + 0.26 * pore) * (0.95 + 0.1 * figure.at(u + r, v))
            shade *= (0.965 + 0.07 * fibre) * (1 + (grain(x, y, 41) - 0.5) * 0.03)
            var color: SIMD3<Float> = base * shade
            color.x *= 1 + (r - 0.5) * 0.05; color.z *= 1 - (r - 0.5) * 0.1 // some boards warmer, some paler
            // Seams: a fine dark line and an eased edge either side; the same at board ends.
            if py == 0 { return color * 0.4 }
            if py == 1 || py == plank - 1 { color *= 0.86 }
            if along == 0 { return color * 0.45 }
            if along == 1 || along == length - 1 { color *= 0.88 }
            return color
        }
    }

    /// Charcoal stone tiles in staggered rows of different lengths, thin pale grout between.
    static func stoneTiles() -> CGImage? {
        let size = 512
        let rows = [96, 72, 104, 80, 88, 72]   // row heights in pixels; they sum to 512
        let widths = [150, 112, 190, 128, 170, 140, 104]
        var state: UInt64 = 99
        func next() -> Int { state = state &* 6364136223846793005 &+ 1442695040888963407; return Int(state >> 33) }
        // Tile edges for each row, wrapping around the image width.
        var edges: [[Int]] = []
        var shades: [[Float]] = []
        for _ in rows {
            var x = next() % 120, row: [Int] = [], tone: [Float] = []
            while x < size + x % 1 { row.append(x); tone.append(0.86 + Float(next() % 100) / 100 * 0.28); x += widths[next() % widths.count]; if x >= size + row[0] { break } }
            edges.append(row); shades.append(tone)
        }
        let layers = [Noise(cells: 8, seed: 21), Noise(cells: 16, seed: 22), Noise(cells: 32, seed: 23), Noise(cells: 64, seed: 24)]
        let base = SIMD3<Float>(0.2, 0.2, 0.205)
        var rowStart = [0]; for h in rows { rowStart.append(rowStart.last! + h) }
        return draw(size: size) { x, y in
            let r = rows.indices.last { rowStart[$0] <= y } ?? 0
            let row = edges[r]
            // Which tile, and how far from its edges (wrapping).
            var tile = row.count - 1
            for (k, edge) in row.enumerated() where edge <= x { tile = k }
            if x < row[0] { tile = row.count - 1 }
            let left = (x - row[tile] + size) % size
            let right = ((tile + 1 < row.count ? row[tile + 1] : row[0] + size) - x + size) % size
            let top = y - rowStart[r], bottom = rowStart[r + 1] - 1 - y
            if min(left, right, top, bottom) < 1 { return SIMD3<Float>(repeating: 0.42) } // grout
            let u = Float(x) / Float(size), v = Float(y) / Float(size)
            let mottle = 0.82 + 0.36 * fbm(layers, u, v)
            let speck = grain(x, y, 3) > 0.985 ? 1.35 : 1 + (grain(x, y, 5) - 0.5) * 0.12
            let bevel: Float = min(left, right, top, bottom) < 3 ? 0.88 : 1
            return base * shades[r][tile] * mottle * speck * bevel
        }
    }
}

/// The first page inside a book: its title set quietly on cream paper.
struct TitlePage: View {
    let title: String
    let author: String
    /// Only the title, in the current foreground style, everything else invisible but in place:
    /// the entrance cuts these exact letters out of the page to dive through them.
    var titleOnly = false

    static let width: CGFloat = 300
    static let titleColor = Color(white: 0.15)

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Text(title)
                .font(.system(size: 24, weight: .medium, design: .serif))
                .foregroundStyle(titleOnly ? AnyShapeStyle(.foreground) : AnyShapeStyle(Self.titleColor))
                .multilineTextAlignment(.center).lineLimit(4).minimumScaleFactor(0.6)
            Group {
                Rectangle().fill(Color(white: 0.6)).frame(width: 28, height: 1)
                if !author.isEmpty {
                    Text(author).font(.system(size: 12, weight: .regular, design: .serif)).foregroundStyle(Color(white: 0.4)).lineLimit(2)
                }
            }
            .opacity(titleOnly ? 0 : 1)
            Spacer()
            Text("句读院").font(.system(size: 9, weight: .medium)).tracking(3).foregroundStyle(Color(white: 0.55))
                .padding(.bottom, 18)
                .opacity(titleOnly ? 0 : 1)
        }
        .padding(.horizontal, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(titleOnly ? Color.clear : Color(red: 0.98, green: 0.965, blue: 0.94))
    }
}

/// The open book at the moment the entrance takes over: a still of the scene, the chosen word on
/// screen, the point the camera is pushing into, and the push itself, so the entrance carries it
/// on without a seam.
struct OpenedPage {
    let snapshot: UIImage?
    /// The scene's size on screen, in points (the snapshot itself is in pixels).
    var screen: CGSize = CGSize(width: 402, height: 874)
    /// The chosen word on screen, in points; nil when there's nothing to dive through.
    var word: CGRect?
    /// That word's letters as a mask over `word` (see `BookPage.Mark.holes`).
    var holes: CGImage?
    /// Where the camera is heading (screen points): the thickest part of one of the word's letters.
    var anchor: CGPoint = .zero
    var dive: DiveCurve?
}

/// The push into the word, as one zoom curve from the moment the camera starts moving until
/// you're through the letter: the 3D camera follows it up to `handoff`, the entrance follows it
/// in 2D from there. Slow at first, always gathering speed, so it reads as one long dive.
struct DiveCurve: Sendable {
    let start: CFTimeInterval     // CACurrentMediaTime
    let duration: Double
    /// log of the whole zoom (until a letter stroke fills the screen).
    let total: Double
    /// log of the zoom when the still was taken.
    var handoff: Double = 0

    /// Eases in (no jolt at the start), then keeps gathering speed.
    static func shape(_ x: Double) -> Double { x * x * (0.35 + 0.65 * x) }
    static func inverse(_ y: Double) -> Double {
        var lo = 0.0, hi = 1.0
        for _ in 0..<40 { let mid = (lo + hi) / 2; if shape(mid) < y { lo = mid } else { hi = mid } }
        return (lo + hi) / 2
    }
    var end: CFTimeInterval { start + duration }
    func zoomLog(at time: CFTimeInterval) -> Double {
        total * Self.shape(min(max((time - start) / duration, 0), 1))
    }
    /// How much bigger the still is drawn at `time`.
    func scale(at time: CFTimeInterval) -> CGFloat { CGFloat(exp(zoomLog(at: time) - handoff)) }
    /// Pulling back out, `u` from 0 to 1: retraces the dive, landing gently on the still.
    func backScale(_ u: Double) -> CGFloat {
        let from = Self.inverse(max(handoff, 0) / max(total, 0.001))
        let t = min(max(u, 0), 1), eased = 1 - pow(1 - t, 3)
        let x = 1 - eased * (1 - from)
        return CGFloat(exp(total * Self.shape(x) - handoff))
    }
}

/// The page you stopped at, as the opened book shows it, and the one word to dive through.
struct InsidePage: Sendable {
    let heading: String
    let text: String
    /// The chosen word, as a UTF-16 range in `text`.
    let word: NSRange
    /// How far into the book this page starts (characters), for its page number.
    var offset: Int = 0
    /// The page begins partway through a paragraph.
    var continues = false
}

/// A page printed like a real book's: a right-hand page with the widest margin at the spine and
/// the deepest at the foot (a 6×9 in trade page: ¾ in gutter, ½ in outside, room for the running
/// head above and the folio below), justified and hyphenated text at about 10½ pt with indented
/// paragraphs and no gaps between them, the chapter as a small letterspaced running head, the
/// page number centred at the foot, and the faint shade where the paper curves into the binding.
enum BookPage {
    /// Design width; the page is drawn at the book's own proportions.
    static let width: CGFloat = 300
    static let paper = UIColor(red: 0.98, green: 0.968, blue: 0.944, alpha: 1)
    static let ink = UIColor(white: 0.12, alpha: 1)

    /// A word on the page, as the dive needs it (design points).
    struct Mark: @unchecked Sendable {
        let word: CGRect
        /// The word's own letters as a mask over `word`: opaque paper, clear where the ink is, so
        /// exactly that one word (and nothing around it) turns into a window.
        let holes: CGImage?
        /// The thickest part of one of its letters, and half that stroke's thickness.
        let point: CGPoint
        let depth: CGFloat
    }

    static func textFrame(_ size: CGSize) -> CGRect {
        let w = size.width
        let inner = w * 0.125, outer = w * 0.085, head = w * 0.15, foot = w * 0.145
        return CGRect(x: inner, y: head, width: w - inner - outer, height: size.height - head - foot)
    }

    nonisolated static func isCJK(_ text: String) -> Bool { cjk(text) }

    private static func cjk(_ text: String) -> Bool {
        text.unicodeScalars.prefix(400).filter { (0x3400...0x9FFF).contains($0.value) }.count > 20
    }

    private static func serif(_ size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        return base.fontDescriptor.withDesign(.serif).map { UIFont(descriptor: $0, size: size) } ?? base
    }

    private final class Laid {
        let storage: NSTextStorage
        let manager = NSLayoutManager()
        let container: NSTextContainer
        let frame: CGRect
        init(_ page: InsidePage, size: CGSize) {
            frame = BookPage.textFrame(size)
            let chinese = BookPage.cjk(page.text)
            let points = size.width * (chinese ? 0.0255 : 0.0245) // ≈ 10½ pt on a 6 in page
            let style = NSMutableParagraphStyle()
            style.alignment = .justified
            style.hyphenationFactor = chinese ? 0 : 1
            style.firstLineHeadIndent = points * (chinese ? 2 : 1.2)
            style.minimumLineHeight = points * (chinese ? 1.5 : 1.32)
            style.maximumLineHeight = style.minimumLineHeight
            style.paragraphSpacing = 0
            storage = NSTextStorage(string: page.text, attributes: [
                .font: BookPage.serif(points), .foregroundColor: BookPage.ink, .paragraphStyle: style,
                .ligature: 1, .kern: chinese ? 0.2 : 0
            ])
            if page.continues {
                // The page starts mid-paragraph, as pages do: its first line isn't indented.
                let first = (page.text as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
                let carried = style.mutableCopy() as! NSMutableParagraphStyle
                carried.firstLineHeadIndent = 0
                storage.addAttribute(.paragraphStyle, value: carried, range: first)
            }
            container = NSTextContainer(size: frame.size)
            container.lineFragmentPadding = 0
            manager.addTextContainer(container)
            storage.addLayoutManager(manager)
            manager.ensureLayout(for: container)
        }
        var visible: NSRange { manager.glyphRange(for: container) }
        var characters: Int { manager.characterRange(forGlyphRange: visible, actualGlyphRange: nil).length }
    }

    /// The printed page, as an image for the 3D book (`scale` pixels per design point).
    nonisolated static func render(_ page: InsidePage, size: CGSize, scale: CGFloat) -> CGImage? {
        let laid = Laid(page, size: size)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            paper.setFill(); cg.fill(CGRect(origin: .zero, size: size))
            // The paper curving into the binding on the left, and just a breath at the fore-edge.
            let space = CGColorSpaceCreateDeviceRGB()
            if let gutter = CGGradient(colorsSpace: space, colors: [UIColor(white: 0, alpha: 0.10).cgColor, UIColor(white: 0, alpha: 0.025).cgColor, UIColor(white: 0, alpha: 0).cgColor] as CFArray, locations: [0, 0.35, 1]) {
                cg.drawLinearGradient(gutter, start: .zero, end: CGPoint(x: size.width * 0.075, y: 0), options: [])
            }
            if let edge = CGGradient(colorsSpace: space, colors: [UIColor(white: 0, alpha: 0).cgColor, UIColor(white: 0, alpha: 0.035).cgColor] as CFArray, locations: [0, 1]) {
                cg.drawLinearGradient(edge, start: CGPoint(x: size.width * 0.975, y: 0), end: CGPoint(x: size.width, y: 0), options: [])
            }
            laid.manager.drawGlyphs(forGlyphRange: laid.visible, at: laid.frame.origin)

            // Running head: the chapter, small and letterspaced, centred over the text.
            let small = size.width * 0.0185
            let head = page.heading.trimmingCharacters(in: .whitespacesAndNewlines)
            if !head.isEmpty {
                let shown = head.count > 48 ? String(head.prefix(46)) + "…" : head
                let text = NSAttributedString(string: cjk(shown) ? shown : shown.uppercased(), attributes: [
                    .font: serif(small), .foregroundColor: UIColor(white: 0.42, alpha: 1), .kern: small * 0.16
                ])
                let w = min(text.size().width, laid.frame.width)
                text.draw(in: CGRect(x: laid.frame.midX - w / 2, y: laid.frame.minY - size.width * 0.072, width: w + 1, height: small * 1.6))
            }
            // Folio: an odd number, as on every right-hand page, from how far in this page is.
            let perPage = max(laid.characters, 400)
            var number = page.offset / perPage + 1
            if number % 2 == 0 { number += 1 }
            let folio = NSAttributedString(string: "\(number)", attributes: [.font: serif(small * 1.12), .foregroundColor: UIColor(white: 0.35, alpha: 1)])
            let fw = folio.size().width
            folio.draw(at: CGPoint(x: laid.frame.midX - fw / 2, y: laid.frame.maxY + size.width * 0.06))
        }
        return image.cgImage
    }

    /// Where the chosen word is printed, and the thickest part of its letters to dive into.
    nonisolated static func mark(_ page: InsidePage, size: CGSize) -> Mark? {
        let laid = Laid(page, size: size)
        let glyphs = laid.manager.glyphRange(forCharacterRange: page.word, actualCharacterRange: nil)
        guard glyphs.length > 0, NSMaxRange(glyphs) <= NSMaxRange(laid.visible) else { return nil }
        var box = laid.manager.boundingRect(forGlyphRange: glyphs, in: laid.container)
        box = box.offsetBy(dx: laid.frame.minX, dy: laid.frame.minY)
        // Draw just the word, big, and find the point deepest inside its ink.
        let scale: CGFloat = 16
        let w = Int((box.width * scale).rounded(.up)), h = Int((box.height * scale).rounded(.up))
        guard w > 2, h > 2, w * h < 4_000_000 else { return nil }
        // Ink of some of the word's glyphs, drawn over the word's box (0 = ink, 255 = paper).
        func ink(_ range: NSRange) -> [UInt8]? {
            var pixels = [UInt8](repeating: 255, count: w * h)
            guard let context = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
            context.translateBy(x: 0, y: CGFloat(h)); context.scaleBy(x: scale, y: -scale) // UIKit's way up: row 0 is the top
            context.translateBy(x: -box.minX, y: -box.minY)
            UIGraphicsPushContext(context)
            laid.manager.drawGlyphs(forGlyphRange: range, at: laid.frame.origin)
            UIGraphicsPopContext()
            return pixels
        }
        guard var pixels = ink(glyphs) else { return nil }
        var d = pixels.map { $0 < 110 ? 1_000_000 : 0 }
        // Two-pass chamfer distance to the paper.
        for y in 0..<h { for x in 0..<w where d[y * w + x] > 0 {
            var v = x > 0 && y > 0 && x < w - 1 && y < h - 1 ? d[y * w + x] : 3
            if x > 0 { v = min(v, d[y * w + x - 1] + 3) }
            if y > 0 { v = min(v, d[(y - 1) * w + x] + 3) }
            if x > 0 && y > 0 { v = min(v, d[(y - 1) * w + x - 1] + 4) }
            if x < w - 1 && y > 0 { v = min(v, d[(y - 1) * w + x + 1] + 4) }
            d[y * w + x] = v
        } }
        for y in stride(from: h - 1, through: 0, by: -1) { for x in stride(from: w - 1, through: 0, by: -1) where d[y * w + x] > 0 {
            var v = d[y * w + x]
            if x < w - 1 { v = min(v, d[y * w + x + 1] + 3) }
            if y < h - 1 { v = min(v, d[(y + 1) * w + x] + 3) }
            if x < w - 1 && y < h - 1 { v = min(v, d[(y + 1) * w + x + 1] + 4) }
            if x > 0 && y < h - 1 { v = min(v, d[(y + 1) * w + x - 1] + 4) }
            d[y * w + x] = v
        } }
        var best = -Double.infinity, bx = w / 2, by = h / 2, depth = 3
        for y in 0..<h { for x in 0..<w where d[y * w + x] > 0 {
            let score = Double(d[y * w + x]) - 0.02 * hypot(Double(x - w / 2), Double(y - h / 2))
            if score > best { best = score; bx = x; by = y; depth = d[y * w + x] }
        } }
        guard best > -Double.infinity else { return nil }
        let point = CGPoint(x: box.minX + (CGFloat(bx) + 0.5) / scale, y: box.minY + (CGFloat(by) + 0.5) / scale)
        // Only the letter you dive into becomes the window; the rest of the word stays printed.
        var letter = NSRange(location: glyphs.location, length: 1), nearest = CGFloat.infinity
        for g in glyphs.location..<NSMaxRange(glyphs) {
            let r = laid.manager.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: laid.container)
                .offsetBy(dx: laid.frame.minX, dy: laid.frame.minY)
            let gap = r.contains(point) ? 0 : hypot(r.midX - point.x, r.midY - point.y)
            if gap < nearest { nearest = gap; letter = NSRange(location: g, length: 1) }
        }
        if let single = ink(letter) { pixels = single }
        // The window: opaque paper, a see-through letter (soft only at its very edges).
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            let ink = 1 - Double(pixels[i]) / 255
            rgba[i * 4 + 3] = UInt8(255 * (1 - max(0, min(1, (ink - 0.12) / 0.55))))
        }
        let holes = CGDataProvider(data: Data(rgba) as CFData).flatMap {
            CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                    provider: $0, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }
        return Mark(word: box, holes: holes,
                    point: point,
                    depth: CGFloat(depth) / 3 / scale)
    }

    /// The word to dive through: one at your reading place (`near`, a UTF-16 offset), long enough
    /// to dive through comfortably.
    static func chooseWord(in text: String, near target: Int) -> NSRange {
        let ns = text as NSString
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var best = NSRange(location: 0, length: min(ns.length, 1)), bestScore = -Double.infinity
        for range in tokenizer.tokens(for: text.startIndex..<text.endIndex) {
            let r = NSRange(range, in: text)
            guard r.location < target + 400 else { break }
            guard r.location > target - 250 else { continue }
            let word = text[range]
            let wide = word.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) }
            let size = Double(word.count) * (wide ? 2.2 : 1)
            guard size >= 4, word.allSatisfy({ $0.isLetter }) else { continue }
            // Closeness to your place matters most (a little after it is fine); then length.
            let distance = Double(r.location - target)
            let score = min(size, 8) * 1.5 - abs(distance < 0 ? distance * 1.6 : distance) / 12
            if score > bestScore { bestScore = score; best = r }
        }
        return best
    }

}
