import SwiftUI
import UIKit

struct ReaderRestoreRequest: Equatable {
    let id = UUID()
    let position: ReadingPosition
}

// The anchor spans original text, its inline translation, and any continuation.
// Keep one persisted scroll coordinate even when a paragraph is split for translation.
struct ReaderParagraphAnchor: UIViewRepresentable {
    let paragraphID: Int
    func makeUIView(context: Context) -> ReaderParagraphAnchorView {
        let view = ReaderParagraphAnchorView()
        view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ view: ReaderParagraphAnchorView, context: Context) { view.paragraphID = paragraphID }
}

final class ReaderParagraphAnchorView: UIView {
    var paragraphID: Int = 0
}

// Observe the native scroll view without replacing SwiftUI's scroll delegate.
struct ReaderScrollObserver: UIViewRepresentable {
    let enabled: Bool
    let restore: ReaderRestoreRequest?
    let onPosition: (ReadingPosition) -> Void
    let onRestored: () -> Void
    let onSeek: (Int) -> Void
    let onBlankTap: () -> Void
    let onInteraction: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> Marker {
        let marker = Marker()
        marker.isUserInteractionEnabled = false
        marker.onAttach = { [weak coordinator = context.coordinator] view in coordinator?.attach(from: view) }
        return marker
    }
    func updateUIView(_ view: Marker, context: Context) {
        context.coordinator.parent = self
        context.coordinator.attach(from: view)
        context.coordinator.restoreIfNeeded()
    }
    static func dismantleUIView(_ view: Marker, coordinator: Coordinator) { coordinator.detach() }

    final class Marker: UIView {
        var onAttach: ((UIView) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            DispatchQueue.main.async { [weak self] in if let self { self.onAttach?(self) } }
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: ReaderScrollObserver
        private weak var scroll: UIScrollView?
        private var observation: NSKeyValueObservation?
        private var layoutObservation: NSKeyValueObservation?
        private var tap: UITapGestureRecognizer?
        private var restoreTask: Task<Void, Never>?
        private var lastRestore: UUID?
        private var restoring = false

        init(_ parent: ReaderScrollObserver) { self.parent = parent }

        func attach(from marker: UIView) {
            guard scroll == nil else { return }
            var ancestor = marker.superview
            while let view = ancestor {
                if let found = view as? UIScrollView {
                    scroll = found
                    observation = found.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                        DispatchQueue.main.async { [weak self] in self?.reportPosition() }
                    }
                    layoutObservation = found.observe(\.contentSize, options: [.new]) { [weak self] _, _ in
                        DispatchQueue.main.async { [weak self] in self?.reportPosition() }
                    }
                    let recognizer = UITapGestureRecognizer(target: self, action: #selector(blankTap))
                    recognizer.cancelsTouchesInView = false
                    recognizer.delegate = self
                    found.addGestureRecognizer(recognizer)
                    tap = recognizer
                    found.panGestureRecognizer.addTarget(self, action: #selector(dragActivity))
                    restoreIfNeeded()
                    return
                }
                ancestor = view.superview
            }
        }

        func detach() {
            restoreTask?.cancel()
            lastRestore = nil
            restoring = false
            observation = nil
            layoutObservation = nil
            if let tap { scroll?.removeGestureRecognizer(tap) }
            scroll?.panGestureRecognizer.removeTarget(self, action: #selector(dragActivity))
            scroll = nil
        }

        private func views<T: UIView>(of type: T.Type) -> [T] {
            guard let scroll else { return [] }
            var result: [T] = []
            func visit(_ view: UIView) {
                if let match = view as? T { result.append(match); return }
                for child in view.subviews { visit(child) }
            }
            visit(scroll)
            return result.filter { $0.bounds.height > 0 }.sorted {
                $0.convert($0.bounds, to: scroll).minY < $1.convert($1.bounds, to: scroll).minY
            }
        }

        private func reportPosition() {
            guard parent.enabled, !restoring, let scroll else { return }
            let top = scroll.contentOffset.y + scroll.adjustedContentInset.top
            if top <= 0.5 {
                parent.onPosition(ReadingPosition(paragraphID: nil, fraction: 0, sentenceID: nil))
                return
            }
            let anchors = views(of: ReaderParagraphAnchorView.self)
            guard let anchor = anchors.first(where: { $0.convert($0.bounds, to: scroll).maxY > top }) ?? anchors.last else { return }
            let rect = anchor.convert(anchor.bounds, to: scroll)
            let fraction = Double((top - rect.minY) / rect.height)
            let fragments = views(of: ReaderParagraphTextView.self).filter { $0.paragraphID == anchor.paragraphID }
            guard let text = fragments.first(where: { $0.convert($0.bounds, to: scroll).maxY > top }) ?? fragments.last else { return }
            let textRect = text.convert(text.bounds, to: scroll)
            var sentenceID: Int?
            if text.attributedText.length > 0, text.layoutManager.numberOfGlyphs > 0 {
                let point = CGPoint(x: 1, y: max(0, top - textRect.minY - text.textContainerInset.top))
                let glyph = text.layoutManager.glyphIndex(for: point, in: text.textContainer)
                let character = min(text.attributedText.length - 1, text.layoutManager.characterIndexForGlyph(at: min(glyph, text.layoutManager.numberOfGlyphs - 1)))
                if let url = text.attributedText.attribute(.link, at: character, effectiveRange: nil) as? URL {
                    sentenceID = Int(url.lastPathComponent)
                }
            }
            parent.onPosition(ReadingPosition(paragraphID: anchor.paragraphID, fraction: fraction, sentenceID: sentenceID))
        }

        func restoreIfNeeded() {
            guard let request = parent.restore, request.id != lastRestore, scroll != nil else { return }
            lastRestore = request.id
            restoreTask?.cancel()
            restoring = true
            restoreTask = Task { @MainActor [weak self] in
                guard let self else { return }
                var stable = 0
                var previous: CGFloat?
                // Lazy paragraphs must first materialize after ScrollViewReader's jump.
                // Keep the paragraph-relative offset through the following layout passes.
                for attempt in 0..<100 {
                    do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
                    guard let scroll = self.scroll else { return }
                    scroll.layoutIfNeeded()
                    let target: CGFloat
                    if let id = request.position.paragraphID {
                        guard let anchor = self.views(of: ReaderParagraphAnchorView.self).first(where: { $0.paragraphID == id }) else {
                            if attempt % 5 == 0 { self.parent.onSeek(id) }
                            continue
                        }
                        let rect = anchor.convert(anchor.bounds, to: scroll)
                        target = rect.minY + rect.height * request.position.fraction - scroll.adjustedContentInset.top
                    } else { target = -scroll.adjustedContentInset.top }
                    let maximum = max(-scroll.adjustedContentInset.top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
                    let clamped = min(maximum, max(-scroll.adjustedContentInset.top, target))
                    scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: clamped), animated: false)
                    if let previous, abs(previous - clamped) < 0.5 { stable += 1 } else { stable = 0 }
                    previous = clamped
                    if stable >= 4 { break }
                }
                self.restoring = false
                self.parent.onRestored()
            }
        }

        @objc private func blankTap() { parent.onBlankTap() }
        @objc private func dragActivity(_ recognizer: UIPanGestureRecognizer) {
            if recognizer.state == .began || recognizer.state == .ended { parent.onInteraction() }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            while let current = view, current !== scroll {
                if current is UIControl || current.accessibilityTraits.contains(.button) { return false }
                if let text = current as? UITextView {
                    guard text is ReaderParagraphTextView else { return false }
                    let point = touch.location(in: text)
                    let containerPoint = CGPoint(x: point.x - text.textContainerInset.left, y: point.y - text.textContainerInset.top)
                    let manager = text.layoutManager
                    guard manager.numberOfGlyphs > 0 else { return true }
                    let glyph = manager.glyphIndex(for: containerPoint, in: text.textContainer)
                    guard glyph < manager.numberOfGlyphs else { return true }
                    let bounds = manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: text.textContainer)
                    return !bounds.contains(containerPoint)
                }
                view = current.superview
            }
            return true
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    }
}
