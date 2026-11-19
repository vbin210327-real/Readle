import SwiftUI
import UIKit
import CoreHaptics

/// The way into a book (文字穿越), straight from the open book itself: the camera closes in on one
/// word of the page you stopped at, and as it gets there the word turns into a window onto the
/// reader and you dive through it. Leaving plays it backwards, back onto the open book.
///
/// The shelf's camera carries the first part of the push in 3D; this takes over on a still of
/// that very frame and carries on along the same curve, so it reads as one move. The zoom runs in
/// Core Animation, so it stays smooth even while the reader is being set up behind it.
@MainActor
final class BookEntrance: ObservableObject {
    @Published private(set) var visible = false
    private(set) var page = OpenedPage(snapshot: nil)
    let canvas = DiveCanvas()

    /// Leaving takes a little less time than arriving.
    static let backDuration = 1.4
    static let openLetters = 0.3

    private var run: Task<Void, Never>?
    private var reveal: (@MainActor () async -> Void)?
    private var arrived: (@MainActor () -> Void)?
    private var revealed = false
    private var opened = false

    /// Posted by the reader each time it has drawn its page.
    static let readerReady = Notification.Name("ReaderReady")
    /// How many times a reader has drawn its page so far.
    private(set) var draws = 0

    init() {
        NotificationCenter.default.addObserver(forName: Self.readerReady, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.draws += 1 }
        }
    }

    /// Waits until a reader draws its page (after `count` draws so far), or the time is up.
    func waitForReader(after count: Int, timeout: Double) async {
        let end = CACurrentMediaTime() + timeout
        while draws <= count && CACurrentMediaTime() < end { try? await Task.sleep(for: .milliseconds(16)) }
    }

    /// `reveal` puts the reader behind the still; `arrived` runs once the entrance is over.
    func enter(page: OpenedPage, reduceMotion: Bool, reveal: @escaping @MainActor () async -> Void,
               arrived: @escaping @MainActor () -> Void) {
        run?.cancel()
        self.page = page
        self.reveal = reveal
        self.arrived = arrived
        revealed = false
        opened = false
        guard let still = page.snapshot?.cgImage, let curve = page.dive, page.word != nil, !reduceMotion else {
            // Nothing to dive through (or Reduce Motion): just go to the page.
            run = Task { @MainActor [weak self] in await self?.finish() }
            return
        }
        // Looks exactly like the scene underneath, and keeps moving the same way.
        canvas.show(still, screen: page.screen, anchor: page.anchor)
        canvas.zoom(curve)
        visible = true
        run = Task { @MainActor [weak self] in
            guard let self else { return }
            // The reader (already set up, out of sight) goes in behind the still…
            await revealOnce()
            canvas.revealBehind(over: 0.12)
            guard !Task.isCancelled else { return }
            // …and the word's letters open into windows onto it.
            if let holes = page.holes, let word = page.word, !Task.isCancelled {
                let cut = Cutout(holes: holes, rect: word)
                canvas.openLetters(cut, over: Self.openLetters)
                opened = true
            }
            let left = curve.end - CACurrentMediaTime()
            if left > 0 { try? await Task.sleep(for: .milliseconds(Int(left * 1000))) }
            guard !Task.isCancelled else { return }
            await finish()
        }
    }

    /// Back to the shelf: pull back out through the letters onto the open book.
    /// Back to the shelf, as one move: the dive plays backwards, out of the letter (the reader
    /// still showing through it), onto the page and back out to the shelf. `back` starts the 3D
    /// half on the shelf; the reader is taken away under the still, so nothing visibly pauses.
    func leave(reduceMotion: Bool, pop: @escaping @MainActor () -> Void,
               back: @escaping @MainActor (CFTimeInterval, Double) -> Void) {
        run?.cancel()
        guard let curve = page.dive, opened, page.snapshot != nil, !reduceMotion else { pop(); return }
        let start = CACurrentMediaTime() + 0.03
        let flat = canvas.pullBack(curve, from: start, over: Self.backDuration, reader: Self.screenImage())
        visible = true
        back(start, Self.backDuration)
        run = Task { @MainActor [weak self] in
            guard let self else { return }
            // Once the still is on screen, the reader goes; the shelf is back behind it, already
            // moving along the same path, by the time the still lets go.
            try? await Task.sleep(for: .milliseconds(60))
            var instant = Transaction(); instant.disablesAnimations = true
            withTransaction(instant) { pop() }
            let left = start + flat - CACurrentMediaTime()
            if left > 0 { try? await Task.sleep(for: .milliseconds(Int(left * 1000))) }
            guard !Task.isCancelled else { return }
            visible = false
        }
    }

    /// What is on screen right now (the reader), to keep showing through the letter as it closes.
    private static func screenImage() -> CGImage? {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }.cgImage
    }

    func reset() {
        run?.cancel(); run = nil
        reveal = nil; arrived = nil; opened = false; visible = false
        page = OpenedPage(snapshot: nil)
    }

    /// A tap during the entrance jumps straight to the page.
    func skip() {
        guard visible else { return }
        DiveHaptics.shared.stop()
        run?.cancel()
        run = Task { @MainActor [weak self] in await self?.finish() }
    }

    private func revealOnce() async {
        guard !revealed, let reveal else { return }
        revealed = true
        await reveal()
    }

    /// The reader is in place and the still goes away.
    private func finish() async {
        await revealOnce()
        visible = false
        let done = arrived
        arrived = nil
        done?()
    }

    /// Sleeps; false if the run was cancelled meanwhile.
    private func pause(_ seconds: Double) async -> Bool {
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
        return !Task.isCancelled
    }

    /// The chosen word's letters as holes in the still, and where on screen they go.
    struct Cutout: @unchecked Sendable {
        let holes: CGImage
        let rect: CGRect      // screen points
    }

}

/// The still of the open book, drawn and moved by Core Animation: zoomed along the dive about the
/// point the camera is heading for, with the word's letters cut into windows.
final class DiveCanvas: UIView {
    /// Blank paper behind the letters until the reader is in place.
    private let backdrop = CALayer()
    private let still = CALayer()
    private let holeMask = CALayer()
    /// The word's area: its letters as holes, under a cover that keeps it printed until they open.
    private let holes = CALayer()
    private let cover = CALayer()
    private var frameParts: [CALayer] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        layer.addSublayer(backdrop)
        layer.addSublayer(still)
        still.contentsGravity = .resize
        for _ in 0..<4 {
            let part = CALayer()
            part.backgroundColor = UIColor.black.cgColor
            frameParts.append(part)
            holeMask.addSublayer(part)
        }
        holeMask.addSublayer(holes)
        cover.backgroundColor = UIColor.black.cgColor
        holeMask.addSublayer(cover)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func quietly(_ change: () -> Void) {
        CATransaction.begin(); CATransaction.setDisableActions(true); change(); CATransaction.commit()
    }

    func show(_ image: CGImage, screen: CGSize, anchor: CGPoint) {
        quietly {
            backdrop.removeAllAnimations()
            backdrop.frame = CGRect(origin: .zero, size: screen)
            backdrop.backgroundColor = UIColor(Palette.paper).resolvedColor(with: traitCollection).cgColor
            backdrop.opacity = 1
            still.removeAllAnimations()
            still.opacity = 1
            still.mask = nil
            still.contents = image
            still.bounds = CGRect(origin: .zero, size: screen)
            still.anchorPoint = CGPoint(x: anchor.x / max(screen.width, 1), y: anchor.y / max(screen.height, 1))
            still.position = anchor
            still.transform = CATransform3DIdentity
        }
    }

    /// Carries the dive on from now to its end, along the same curve the camera was on.
    func zoom(_ curve: DiveCurve) {
        let now = CACurrentMediaTime(), span = max(curve.end - now, 0.05)
        let samples = 90
        let values = (0...samples).map { k in curve.scale(at: now + span * Double(k) / Double(samples)) }
        animateScale(values, from: now, over: span)
        // Through: the last of the page melts away as the letter fills the screen.
        let vanish = CABasicAnimation(keyPath: "opacity")
        vanish.fromValue = 1; vanish.toValue = 0
        vanish.beginTime = still.convertTime(curve.end - 0.18, from: nil)
        vanish.duration = 0.18
        vanish.fillMode = .forwards
        vanish.isRemovedOnCompletion = false
        still.add(vanish, forKey: "vanish")
    }

    /// The letters turn into windows (the rest of the page stays as it is).
    func openLetters(_ cut: BookEntrance.Cutout, over seconds: Double) {
        let r = cut.rect, b = still.bounds
        quietly {
            holeMask.frame = b
            // Opaque all around the word (overlapping it a little, so no seams), holes in it.
            frameParts[0].frame = CGRect(x: 0, y: 0, width: b.width, height: r.minY + 1)
            frameParts[1].frame = CGRect(x: 0, y: r.maxY - 1, width: b.width, height: b.height - r.maxY + 1)
            frameParts[2].frame = CGRect(x: 0, y: r.minY, width: r.minX + 1, height: r.height)
            frameParts[3].frame = CGRect(x: r.maxX - 1, y: r.minY, width: b.width - r.maxX + 1, height: r.height)
            holes.frame = r
            holes.contents = cut.holes
            holes.contentsGravity = .resize
            cover.frame = r
            cover.opacity = 0
            still.mask = holeMask
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1; fade.toValue = 0
        fade.duration = seconds
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        cover.add(fade, forKey: "open")
    }

    /// The reader is in place: the blank page behind the letters melts away to show it.
    func revealBehind(over seconds: Double) {
        quietly { backdrop.opacity = 0 }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1; fade.toValue = 0
        fade.duration = seconds
        backdrop.add(fade, forKey: "reveal")
    }

    /// Back out along the dive, landing on the still, then the letters print again.
    /// The dive backwards, from `start` over `seconds` in all; this part runs until the still is
    /// back where the camera handed over (returned, in seconds). The letter shows the reader until
    /// just before then, when it prints again.
    func pullBack(_ curve: DiveCurve, from start: CFTimeInterval, over seconds: Double, reader: CGImage?) -> Double {
        let handoff = DiveCurve.inverse(max(curve.handoff, 0) / max(curve.total, 0.001))
        let flat = (1 - handoff) * seconds
        let samples = 60
        let values = (0...samples).map { k -> CGFloat in
            let x = 1 - (1 - handoff) * Double(k) / Double(samples)
            return CGFloat(exp(curve.total * DiveCurve.shape(x) - curve.handoff))
        }
        quietly {
            for layer in [cover, still, backdrop] { layer.removeAllAnimations() }
            backdrop.contents = reader
            backdrop.contentsGravity = .resize
            backdrop.opacity = 1
            cover.opacity = 1
            still.opacity = 1
        }
        animateScale(values, from: start, over: flat)
        // Coming out of the letter: the page around it fades back in as you leave it.
        let appear = CABasicAnimation(keyPath: "opacity")
        appear.fromValue = 0; appear.toValue = 1
        appear.beginTime = still.convertTime(start, from: nil)
        appear.duration = 0.18
        appear.fillMode = .backwards
        still.add(appear, forKey: "appear")
        // The letter prints again just before the shelf takes over.
        let close = CABasicAnimation(keyPath: "opacity")
        close.fromValue = 0; close.toValue = 1
        close.beginTime = cover.convertTime(start + max(flat - 0.24, 0.1), from: nil)
        close.duration = 0.22
        close.fillMode = .backwards
        close.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        cover.add(close, forKey: "close")
        return flat
    }

    private func animateScale(_ values: [CGFloat], from now: CFTimeInterval, over seconds: Double) {
        guard let last = values.last else { return }
        quietly { still.transform = CATransform3DMakeScale(last, last, 1) }
        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = values
        scale.calculationMode = .linear
        scale.beginTime = still.convertTime(now, from: nil)
        scale.duration = seconds
        scale.fillMode = .backwards
        still.add(scale, forKey: "dive")
    }
}

/// Sits above everything while a book is entered or left.
struct EntranceOverlay: View {
    @ObservedObject var entrance: BookEntrance

    var body: some View {
        if entrance.visible {
            DiveSurface(canvas: entrance.canvas)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { entrance.skip() }
                .accessibilityHidden(true)
        }
    }
}

private struct DiveSurface: UIViewRepresentable {
    let canvas: DiveCanvas
    func makeUIView(context: Context) -> DiveCanvas { canvas }
    func updateUIView(_ view: DiveCanvas, context: Context) {}
}

extension EnvironmentValues {
    /// Set by the shelf: how the reader's back button returns, so it can fly back out.
    @Entry var closeBook: (() -> Void)? = nil
    /// False while a reader is being set up out of sight, so it leaves the status bar alone.
    @Entry var readerOnScreen = true
}

/// What the dive feels like in the hand: a faint texture that builds with the zoom (pressure as you
/// close in on the page), then one crisp tap as you break through the letter, then nothing.
/// Uses Core Haptics, which follows the system's haptics setting; without it, just the final tap.
@MainActor
final class DiveHaptics {
    static let shared = DiveHaptics()
    /// Peak strength of the building texture (0…1), and of the break-through tap.
    static let texturePeak: Float = 0.3
    static let breakThrough: Float = 0.5

    private var engine: CHHapticEngine?
    private var players: [CHHapticPatternPlayer] = []
    private let fallback = UIImpactFeedbackGenerator(style: .rigid)
    private var fallbackTask: Task<Void, Never>?

    private init() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        engine = try? CHHapticEngine()
        engine?.playsHapticsOnly = true
        engine?.isAutoShutdownEnabled = true
        engine?.resetHandler = { [weak self] in
            Task { @MainActor in try? self?.engine?.start() }
        }
    }

    /// Plays along a dive starting now and lasting `duration` seconds.
    func play(_ curve: DiveCurve) {
        stop()
        let duration = max(curve.end - CACurrentMediaTime(), 0.2)
        guard let engine else {
            fallback.prepare()
            fallbackTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(Int(duration * 1000)))
                guard !Task.isCancelled else { return }
                self?.fallback.impactOccurred(intensity: CGFloat(Self.breakThrough))
            }
            return
        }
        do {
            try engine.start()
            // The texture: one long continuous event, its strength following the zoom.
            let hum = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.2),
            ], relativeTime: 0, duration: duration)
            let steps = 14
            let strength = (0...steps).map { k -> CHHapticParameterCurve.ControlPoint in
                let x = Double(k) / Double(steps)
                let value = Self.texturePeak * Float(pow(DiveCurve.shape(x), 0.5))
                return .init(relativeTime: duration * x, value: value)
            }
            let edge = (0...steps).map { k -> CHHapticParameterCurve.ControlPoint in
                let x = Double(k) / Double(steps)
                return .init(relativeTime: duration * x, value: Float(0.3 * x)) // a little crisper as it nears
            }
            let texture = try CHHapticPattern(events: [hum], parameterCurves: [
                CHHapticParameterCurve(parameterID: .hapticIntensityControl, controlPoints: strength, relativeTime: 0),
                CHHapticParameterCurve(parameterID: .hapticSharpnessControl, controlPoints: edge, relativeTime: 0),
            ])
            // Breaking through: one crisp tap the moment the letter fills the screen.
            let tap = try CHHapticPattern(events: [CHHapticEvent(eventType: .hapticTransient, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: Self.breakThrough),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.45),
            ], relativeTime: 0)], parameters: [])
            let hold = try engine.makePlayer(with: texture)
            let snap = try engine.makePlayer(with: tap)
            try hold.start(atTime: CHHapticTimeImmediate)
            try snap.start(atTime: engine.currentTime + duration)
            players = [hold, snap]
        } catch {
            players = []
        }
    }

    func stop() {
        fallbackTask?.cancel()
        for player in players { try? player.stop(atTime: CHHapticTimeImmediate) }
        players = []
    }
}
