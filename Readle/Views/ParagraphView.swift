import SwiftUI
import UIKit
import NaturalLanguage

struct ParagraphView: UIViewRepresentable {
    let paragraph: Paragraph
    var sentenceRange: Range<Int>? = nil
    let selectedID: Int?
    var speakingIDs: Set<Int> = []
    let fontSize: Double
    var annotations: [Int: [String: String]] = [:]
    var annotationColor: Color = Palette.accent
    var onWord: ((String, Sentence) -> Void)? = nil
    let onSelect: (Sentence) -> Void
    @Environment(\.sizeCategory) private var sizeCategory

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextView {
        let view = ReaderParagraphTextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.delegate = context.coordinator
        let hold = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.selectSentence(_:)))
        hold.minimumPressDuration = 0.45
        view.addGestureRecognizer(hold)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.lookupWord(_:)))
        tap.require(toFail: hold)
        view.addGestureRecognizer(tap)
        for recognizer in view.gestureRecognizers ?? [] where recognizer !== hold && recognizer is UILongPressGestureRecognizer {
            recognizer.require(toFail: hold)
        }
        for recognizer in view.gestureRecognizers ?? [] where recognizer !== tap && recognizer is UITapGestureRecognizer {
            recognizer.require(toFail: tap)
        }
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // Sentences are stored as links; an empty dictionary lets each run keep its own color and underline.
        view.linkTextAttributes = [:]
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        let descriptor = UIFont.systemFont(ofSize: fontSize).fontDescriptor.withDesign(.serif) ?? UIFont.systemFont(ofSize: fontSize).fontDescriptor
        let font = UIFontMetrics(forTextStyle: .body).scaledFont(for: UIFont(descriptor: descriptor, size: fontSize))
        let style = NSMutableParagraphStyle()
        style.lineSpacing = font.pointSize * (annotations.isEmpty ? 0.36 : 1.0)
        style.paragraphSpacing = 0
        let text = NSMutableAttributedString()
        for sentence in paragraph.sentences[sentenceRange ?? paragraph.sentences.indices] {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: UIColor.label, .paragraphStyle: style,
                .link: URL(string: "readle://sentence/\(sentence.id)")!
            ]
            if selectedID == sentence.id {
                attributes[.backgroundColor] = UIColor(Palette.accent).withAlphaComponent(0.15)
            }
            if speakingIDs.contains(sentence.id) {
                attributes[.backgroundColor] = UIColor(Palette.accent).withAlphaComponent(0.12)
            }
            let start = text.length
            text.append(NSAttributedString(string: sentence.text, attributes: attributes))
            if let meanings = annotations[sentence.id], !meanings.isEmpty {
                let tokenizer = NLTokenizer(unit: .word)
                tokenizer.string = sentence.text
                tokenizer.enumerateTokens(in: sentence.text.startIndex..<sentence.text.endIndex) { range, _ in
                    let word = String(sentence.text[range])
                    guard let meaning = meanings.first(where: { $0.key.localizedCaseInsensitiveCompare(word) == .orderedSame })?.value else { return true }
                    let location = NSRange(range, in: sentence.text)
                    text.addAttribute(.init("ReadleAnnotation"), value: meaning,
                                      range: NSRange(location: start + location.location, length: location.length))
                    return true
                }
            }
        }
        if !view.attributedText.isEqual(to: text) { view.attributedText = text }
        if let paragraphView = view as? ReaderParagraphTextView {
            paragraphView.paragraphID = paragraph.id
            let coverColor = UIColor(annotationColor)
            paragraphView.annotationColor = UIColor { traits in
                let resolved = coverColor.resolvedColor(with: traits)
                guard traits.userInterfaceStyle != .dark else { return resolved }
                var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
                guard resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return resolved }
                func linear(_ component: CGFloat) -> CGFloat {
                    component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
                }
                let luminance = 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
                guard luminance > 0.48 else { return resolved }
                var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0
                guard resolved.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else { return resolved }
                return UIColor(hue: hue, saturation: saturation, brightness: min(brightness, 0.65), alpha: alpha)
            }
            paragraphView.annotationFont = UIFont.systemFont(ofSize: max(10, font.pointSize * 0.5), weight: .medium)
            paragraphView.textContainerInset.top = annotations.isEmpty ? 0 : font.pointSize * 0.65
            paragraphView.setNeedsDisplay()
        }
        let continuation = (sentenceRange?.lowerBound ?? 0) > 0
        view.accessibilityIdentifier = "paragraph-\(paragraph.id)" + (continuation ? "-continuation" : "")
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let height = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: width, height: height)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ParagraphView
        init(_ parent: ParagraphView) { self.parent = parent }
        @objc func lookupWord(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, let view = gesture.view as? UITextView else { return }
            handleGesture(gesture, in: view, word: true)
        }
        @objc func selectSentence(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began, let view = gesture.view as? UITextView else { return }
            handleGesture(gesture, in: view, word: false)
        }
        private func handleGesture(_ gesture: UIGestureRecognizer, in view: UITextView, word: Bool) {
            let touch = gesture.location(in: view)
            let point = CGPoint(x: touch.x - view.textContainerInset.left, y: touch.y - view.textContainerInset.top)
            let manager = view.layoutManager
            guard manager.numberOfGlyphs > 0 else { return }
            let glyph = manager.glyphIndex(for: point, in: view.textContainer)
            guard glyph < manager.numberOfGlyphs,
                  manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: view.textContainer).contains(point) else { return }
            let index = manager.characterIndexForGlyph(at: glyph)
            let string = view.attributedText.string
            guard index < (string as NSString).length,
                  let url = view.attributedText.attribute(.link, at: index, effectiveRange: nil) as? URL,
                  let id = Int(url.lastPathComponent),
                  let sentence = parent.paragraph.sentences.first(where: { $0.id == id }) else { return }
            view.selectedRange = NSRange(location: NSNotFound, length: 0)
            guard word else { parent.onSelect(sentence); return }
            let tokenizer = NLTokenizer(unit: .word)
            tokenizer.string = string
            let location = String.Index(utf16Offset: index, in: string)
            let range = tokenizer.tokenRange(at: location)
            let word = String(string[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard word.rangeOfCharacter(from: .letters) != nil else { return }
            parent.onWord?(word, sentence)
        }
        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
            nil
        }
        func textView(_ textView: UITextView, menuConfigurationFor textItem: UITextItem, defaultMenu: UIMenu) -> UITextItem.MenuConfiguration? {
            nil
        }
    }
}

final class ReaderParagraphTextView: UITextView {
    var paragraphID: Int = 0
    var annotationColor = UIColor.label
    var annotationFont = UIFont.systemFont(ofSize: 11)

    override func draw(_ rect: CGRect) {
        super.draw(rect)
        let full = NSRange(location: 0, length: attributedText.length)
        attributedText.enumerateAttribute(.init("ReadleAnnotation"), in: full) { value, range, _ in
            guard let meaning = value as? String else { return }
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let wordRect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
                .offsetBy(dx: textContainerInset.left, dy: textContainerInset.top)
            let attributes: [NSAttributedString.Key: Any] = [.font: annotationFont, .foregroundColor: annotationColor]
            let size = (meaning as NSString).size(withAttributes: attributes)
            let x = max(0, min(bounds.width - size.width, wordRect.midX - size.width / 2))
            (meaning as NSString).draw(at: CGPoint(x: x, y: wordRect.minY - size.height), withAttributes: attributes)
        }
    }
}
