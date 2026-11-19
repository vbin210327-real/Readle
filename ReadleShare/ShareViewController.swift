import UIKit
import UniformTypeIdentifiers

/// The share sheet: shows the book being handed to 句读院 as a small cover in the app's own style,
/// then one button that opens 句读院, where the import finishes.
final class ShareViewController: UIViewController {
    private let brand = UILabel()
    private let closeButton = UIButton(type: .system)
    private let cover = BookCoverView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let bookTitle = UILabel()
    private let meta = UILabel()
    private let message = UILabel()
    private let action = UIButton(type: .system)
    private var progress: Progress?
    private var finished = false
    private var state = State.saving

    private enum State { case saving, queued, failed }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        preferredContentSize = CGSize(width: 420, height: 360)

        brand.text = "句读院"
        brand.font = .preferredFont(forTextStyle: .footnote).withWeight(.semibold)
        brand.textColor = .secondaryLabel
        brand.adjustsFontForContentSizeCategory = true

        closeButton.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)), for: .normal)
        closeButton.tintColor = .secondaryLabel
        closeButton.backgroundColor = .tertiarySystemFill
        closeButton.layer.cornerRadius = 15
        closeButton.accessibilityLabel = "关闭"
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        NSLayoutConstraint.activate([closeButton.widthAnchor.constraint(equalToConstant: 30), closeButton.heightAnchor.constraint(equalToConstant: 30)])
        let top = UIStackView(arrangedSubviews: [brand, UIView(), closeButton])
        top.alignment = .center

        // The book, as it will sit on the shelf.
        cover.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([cover.widthAnchor.constraint(equalToConstant: 76), cover.heightAnchor.constraint(equalToConstant: 104)])
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.color = .white
        cover.addSubview(spinner)
        NSLayoutConstraint.activate([spinner.centerXAnchor.constraint(equalTo: cover.centerXAnchor), spinner.centerYAnchor.constraint(equalTo: cover.centerYAnchor)])

        bookTitle.font = UIFont.serif(size: 22, weight: .semibold)
        bookTitle.textColor = .label
        bookTitle.numberOfLines = 3
        bookTitle.lineBreakMode = .byTruncatingTail
        bookTitle.text = "正在读取…"
        meta.font = .preferredFont(forTextStyle: .footnote)
        meta.textColor = .secondaryLabel
        meta.adjustsFontForContentSizeCategory = true
        meta.text = "正在保存"
        let titles = UIStackView(arrangedSubviews: [bookTitle, meta])
        titles.axis = .vertical
        titles.spacing = 6
        let book = UIStackView(arrangedSubviews: [cover, titles])
        book.alignment = .center
        book.spacing = 18

        message.font = .preferredFont(forTextStyle: .body)
        message.adjustsFontForContentSizeCategory = true
        message.textColor = .label
        message.numberOfLines = 0
        message.text = "请打开句读院完成导入"
        message.alpha = 0

        var configuration = UIButton.Configuration.filled()
        configuration.title = "打开句读院"
        configuration.baseBackgroundColor = .label
        configuration.baseForegroundColor = .systemBackground
        configuration.cornerStyle = .large
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 15, leading: 20, bottom: 15, trailing: 20)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .preferredFont(forTextStyle: .headline)
            return outgoing
        }
        action.configuration = configuration
        action.isEnabled = false
        action.accessibilityIdentifier = "readleShareDone"
        action.addTarget(self, action: #selector(primaryAction), for: .touchUpInside)
        action.isPointerInteractionEnabled = true

        let stack = UIStackView(arrangedSubviews: [top, book, message, action])
        stack.axis = .vertical
        stack.spacing = 26
        stack.setCustomSpacing(18, after: top)
        stack.setCustomSpacing(22, after: book)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        // Fills a phone's width; in iPad's wider share sheet it keeps to a readable column.
        let fill = stack.widthAnchor.constraint(equalTo: view.safeAreaLayoutGuide.widthAnchor, constant: -48)
        fill.priority = .defaultHigh
        NSLayoutConstraint.activate([
            fill,
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 460),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24)
        ])
        cover.alpha = 0.55
        spinner.startAnimating()
        receive()
    }

    private func receive() {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        guard let provider = providers.first else { show(.failure(ImportError.message("没有收到文件，请从电子书文件的分享菜单重试。"))); return }
        guard providers.count == 1 else { show(.failure(ImportError.message("请一次分享一本电子书。"))); return }
        if let name = provider.suggestedName { showName(name) }
        let supported = ["com.amazon.mobi", "com.mobipocket.mobi", "org.idpf.epub-container", UTType.pdf.identifier, UTType.plainText.identifier]
        if let type = supported.first(where: { provider.hasItemConformingToTypeIdentifier($0) }) {
            progress = provider.loadFileRepresentation(forTypeIdentifier: type) { [weak self] url, error in
                do {
                    guard let url else { throw error ?? ImportError.message("文件尚未下载完成，请下载后重新分享。") }
                    let ext = type.contains("mobi") ? "mobi" : type == UTType.pdf.identifier ? "pdf" : type == UTType.plainText.identifier ? "txt" : "epub"
                    var name = provider.suggestedName ?? url.lastPathComponent
                    if (name as NSString).pathExtension.lowercased() != ext { name += "." + ext }
                    // NSItemProvider deletes this temporary URL after the callback returns.
                    _ = try SharedImportInbox().enqueue(url, name: name)
                    self?.show(.success(name))
                } catch { self?.show(.failure(error)) }
            }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, error in
                do {
                    let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                    guard let url else { throw error ?? ImportError.message("请分享电子书文件，而不是网页链接。") }
                    _ = try SharedImportInbox().enqueue(url)
                    self?.show(.success(url.lastPathComponent))
                } catch { self?.show(.failure(error)) }
            }
        } else { show(.failure(ImportError.message("请选择 EPUB、MOBI、TXT 或 PDF 电子书文件。"))) }
    }

    /// "海边的灯塔.txt" → title "海边的灯塔", format "TXT".
    private func showName(_ file: String) {
        let base = (file as NSString).lastPathComponent
        let ext = (base as NSString).pathExtension
        let title = ext.isEmpty ? base : (base as NSString).deletingPathExtension
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.bookTitle.text = title
            self.cover.title = title
            if !ext.isEmpty { self.meta.text = ext.uppercased() + " · 正在保存" }
        }
    }

    private func show(_ result: Result<String, Error>) {
        if case .success(let name) = result { showName(name) }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.finished else { return }
            self.spinner.stopAnimating()
            switch result {
            case .success(let name):
                self.state = .queued
                let ext = ((name as NSString).lastPathComponent as NSString).pathExtension.uppercased()
                self.meta.text = (ext.isEmpty ? "" : ext + " · ") + "正在导入句读院"
                self.message.text = "请打开句读院完成导入"
                self.action.isEnabled = true
                self.action.configuration?.title = "打开句读院"
                UIView.animate(withDuration: 0.25) {
                    self.cover.alpha = 1
                    self.message.alpha = 1
                }
            case .failure(let error):
                self.state = .failed
                self.cover.isHidden = true
                self.bookTitle.text = "无法导入"
                self.meta.isHidden = true
                self.message.text = error.localizedDescription
                self.message.textColor = .secondaryLabel
                self.message.alpha = 1
                self.action.isEnabled = true
                self.action.configuration?.title = "关闭"
            }
        }
    }

    /// iPad keyboards: Return does the main action, Esc closes.
    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(title: "打开句读院", action: #selector(primaryAction), input: "\r"),
         UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(close))]
    }

    @objc private func primaryAction() {
        switch state {
        case .saving: return
        case .queued: openApp()
        case .failed: close()
        }
    }

    /// Opens 句读院, which collects the book from the shared inbox as it comes to the front.
    /// Extensions can't call UIApplication.shared, so this finds the application object through
    /// the responder chain and asks it to open the app's link.
    private func openApp() {
        guard let url = URL(string: "readle-share://import") else { return close() }
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication, application.responds(to: selector) {
                typealias Open = @convention(c) (NSObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void
                let open = unsafeBitCast(application.method(for: selector), to: Open.self)
                open(application, selector, url as NSURL, NSDictionary(), nil)
                break
            }
            responder = current.next
        }
        close()
    }

    @objc private func close() {
        finished = true
        progress?.cancel()
        extensionContext?.completeRequest(returningItems: nil)
    }
}

/// A small cover in the app's shelf style: a dark board with a spine line, the title in serif, and
/// the house name at the foot.
private final class BookCoverView: UIView {
    var title: String = "" { didSet { titleLabel.text = title } }
    private let titleLabel = UILabel()
    private let house = UILabel()
    private let spine = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(red: 0.20, green: 0.185, blue: 0.175, alpha: 1)
        layer.cornerRadius = 4
        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.22
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 4)
        spine.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        titleLabel.font = UIFont.serif(size: 12, weight: .semibold)
        titleLabel.textColor = UIColor(white: 0.96, alpha: 1)
        titleLabel.numberOfLines = 4
        house.text = "句读院"
        house.font = .systemFont(ofSize: 7, weight: .medium)
        house.textColor = UIColor(white: 1, alpha: 0.55)
        for view in [spine, titleLabel, house] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            spine.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            spine.topAnchor.constraint(equalTo: topAnchor),
            spine.bottomAnchor.constraint(equalTo: bottomAnchor),
            spine.widthAnchor.constraint(equalToConstant: 1),
            titleLabel.leadingAnchor.constraint(equalTo: spine.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -7),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            house.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            house.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
        ])
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: 4).cgPath
    }
}

private extension UIFont {
    static func serif(size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.serif) else { return base }
        return UIFont(descriptor: descriptor, size: size)
    }

    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        UIFont(descriptor: fontDescriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight]]), size: pointSize)
    }
}
