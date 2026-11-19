import SwiftUI
import StoreKit
import PhotosUI
import ImageIO

/// 我的: your membership, how much you've read, a few reading settings, and about the app.
struct AccountView: View {
    @ObservedObject var membership: Membership
    @ObservedObject private var stats = ReadingStats.shared
    let bookCount: Int
    @Environment(\.dismiss) private var dismiss
    @Environment(\.requestReview) private var requestReview
    @AppStorage("readerFontSize") private var fontSize = 21.0
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.system.rawValue
    @State private var showPaywall = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    ProfileHeader()
                    MembershipCard(membership: membership) { showPaywall = true }
                    section("阅读") { statsGrid }
                    section("设置") { settings }
                    section("关于") { about }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 40)
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity)
            }
            .background(AccountColors.page.ignoresSafeArea())
            .navigationTitle("我的")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(AccountColors.page, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 15, weight: .semibold))
                    }
                    .tint(Palette.ink)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("关闭")
                }
            }
        }
        .tint(Palette.accent)
        .fullScreenCover(isPresented: $showPaywall) { MembershipOfferView(access: membership) }
        .preferredColorScheme(AppAppearance(rawValue: appearance)?.scheme)
        .task { await membership.start() }
    }

    // MARK: Sections

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Palette.muted)
                .padding(.leading, 4)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private var statsGrid: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                StatTile(value: Self.duration(stats.totalSeconds), label: "累计阅读")
                StatTile(value: "\(stats.streak)", unit: "天", label: "连续阅读")
            }
            GridRow {
                StatTile(value: "\(stats.finishedCount)", unit: "本", label: "已读完")
                StatTile(value: "\(bookCount)", unit: "本", label: "书架")
            }
        }
    }

    private var settings: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("阅读字号")
                    Spacer()
                    Text("\(Int(fontSize))").monospacedDigit().foregroundStyle(Palette.muted)
                }
                HStack(spacing: 12) {
                    Image(systemName: "textformat.size.smaller").foregroundStyle(Palette.muted)
                    Slider(value: $fontSize, in: 16...30, step: 1)
                        .accessibilityLabel("阅读字号")
                        .accessibilityValue("\(Int(fontSize))")
                    Image(systemName: "textformat.size.larger").foregroundStyle(Palette.muted)
                }
                Text("清晨的阳光落在书页上。")
                    .font(.system(size: fontSize, design: .serif))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 14)
            Divider()
            HStack {
                Text("外观")
                Spacer()
                Picker("外观", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .frame(width: 190)
            }
            .padding(.vertical, 12)
        }
    }

    private var about: some View {
        Card {
            row("给句读院评分", symbol: "star") { requestReview() }
            Divider()
            Link(destination: ReadlePrivacy.policyURL) { rowLabel("隐私政策", symbol: "hand.raised") }
                .buttonStyle(.plain)
            Divider()
            Link(destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!) {
                rowLabel("使用条款", symbol: "doc.text")
            }
            .buttonStyle(.plain)
            Divider()
            HStack {
                RowTitle(title: "版本", symbol: "info.circle")
                Spacer()
                Text(Self.version).monospacedDigit().foregroundStyle(Palette.muted)
            }
            .padding(.vertical, 13)
            .accessibilityElement(children: .combine)
        }
    }

    private func row(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { rowLabel(title, symbol: symbol) }.buttonStyle(.plain)
    }

    private func rowLabel(_ title: String, symbol: String) -> some View {
        HStack {
            RowTitle(title: title, symbol: symbol)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 13)
        .contentShape(Rectangle())
        .hoverEffect(.highlight)
    }

    // MARK: Formatting

    private static func duration(_ seconds: Int) -> String {
        let minutes = seconds / 60
        // A few seconds of reading still shows as reading, not as nothing.
        if seconds > 0, minutes == 0 { return "< 1 分钟" }
        if minutes < 60 { return "\(minutes) 分钟" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours) 小时" : "\(hours) 小时 \(rest) 分"
    }

    /// The marketing version written out in full, "1.0" as "1.0.0".
    private static var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        var parts = short.split(separator: ".").map(String.init)
        while parts.count < 3 { parts.append("0") }
        return parts.joined(separator: ".")
    }
}

// MARK: - Membership card

private struct MembershipCard: View {
    @ObservedObject var membership: Membership
    let upgrade: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize = 31.0
    @ScaledMetric(relativeTo: .subheadline) private var statusSize = 15.0
    @ScaledMetric(relativeTo: .headline) private var actionSize = 16.0
    @State private var width: CGFloat = 360

    var body: some View {
        let edge = width * 0.065
        let top = 26 * width / 360
        let bottom = width * 0.082
        let outline = RoundedRectangle(cornerRadius: width * 0.067, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(membership.isPro ? "句读院高级版" : "普通版")
                    .font(.system(size: titleSize * width / 360, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                Text(status)
                    .font(.system(size: statusSize * width / 360, weight: .medium))
                    .foregroundStyle(Color(white: 0.68))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, width * 0.014)

            Spacer(minLength: width * 0.09)

            if showsActions {
                if typeSize.isAccessibilitySize {
                    VStack(spacing: 12) { actions }
                } else {
                    HStack(spacing: width * 0.033) { actions }
                }
            }

            if let message = membership.message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Color(white: 0.75))
                    .padding(.top, 12)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, edge)
        .padding(.top, top)
        .padding(.bottom, bottom)
        .frame(maxWidth: .infinity, minHeight: width * 0.707, alignment: .topLeading)
        .background {
            outline.fill(.white)
                .colorEffect(ShaderLibrary.membershipSurface(.boundingRect))
                .accessibilityHidden(true)
        }
        .overlay {
            outline.strokeBorder(rim, lineWidth: 0.8)
                .allowsHitTesting(false)
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
        .accessibilityElement(children: .contain)
    }

    private var rim: LinearGradient {
        LinearGradient(stops: [
            .init(color: .white.opacity(0.83), location: 0),
            .init(color: .white.opacity(0.65), location: 0.21),
            .init(color: .white.opacity(0.17), location: 0.49),
            .init(color: .white.opacity(0.28), location: 0.71),
            .init(color: .white.opacity(0.76), location: 1),
        ], startPoint: .top, endPoint: .bottomTrailing)
    }

    private var showsActions: Bool {
        guard membership.isPro else { return true }
        guard let plan = membership.plan else { return false }
        return ReadlePlan.subscriptions.contains(plan)
    }

    @ViewBuilder private var actions: some View {
        if membership.isPro {
            pill("管理订阅", filled: true) { Task { await membership.manageSubscriptions() } }
        } else {
            pill(membership.expiredPlan == nil ? "升级高级版" : "续订高级版", filled: true, action: upgrade)
        }
        pill("恢复购买", filled: false) { Task { await membership.restore() } }
            .frame(width: typeSize.isAccessibilitySize ? nil : width * 0.365)
            .disabled(membership.busy)
            .opacity(membership.busy ? 0.55 : 1)
    }

    private var status: String {
        guard membership.isPro else {
            return membership.expiredPlan == nil ? "升级以解锁全部功能" : "高级版订阅已到期"
        }
        guard let plan = membership.plan else { return "高级版已开通" }
        return plan.title + "会员"
    }

    private func pill(_ title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: actionSize * width / 360, weight: .semibold))
                .foregroundStyle(filled ? Color(white: 0.06) : .white)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, minHeight: max(44, width * (filled ? 0.126 : 0.118)))
                .background {
                    let tones = filled ? [0.98, 0.83, 0.77, 0.87] : [0.17, 0.105, 0.082, 0.15]
                    Capsule()
                        .fill(LinearGradient(colors: tones.map { Color(white: $0) },
                                             startPoint: .topLeading, endPoint: .bottom))
                }
                .overlay {
                    Capsule().strokeBorder(
                        LinearGradient(colors: [.white.opacity(filled ? 0.95 : 0.67),
                                                .white.opacity(filled ? 0.44 : 0.22),
                                                .white.opacity(filled ? 0.9 : 0.62)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 0.8
                    )
                    .allowsHitTesting(false)
                }
                .contentShape(Capsule())
                .hoverEffect(.lift)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Pieces

private struct StatTile: View {
    let value: String
    var unit: String? = nil
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 22, weight: .semibold, design: .serif))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let unit {
                    Text(unit).font(.subheadline).foregroundStyle(Palette.muted)
                }
            }
            Text(label).font(.footnote).foregroundStyle(Palette.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(AccountColors.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// An icon in a fixed column, so every row's title starts at the same place.
private struct RowTitle: View {
    let title: String
    let symbol: String
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).frame(width: 24).accessibilityHidden(true)
            Text(title)
        }
    }
}

private struct Card<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .padding(.horizontal, 16)
            .background(AccountColors.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private enum AccountColors {
    static let page = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.04, alpha: 1) : UIColor(white: 0.955, alpha: 1) })
    static let card = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.11, alpha: 1) : .white })
}

// MARK: - Appearance

/// The app's light or dark appearance, or the system's.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    static let key = "readle.appearance"
    var id: String { rawValue }
    var title: String {
        switch self { case .system: "跟随系统"; case .light: "浅色"; case .dark: "深色" }
    }
    var scheme: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .dark: .dark }
    }
}

// MARK: - Privacy

enum ReadlePrivacy {
    static let policyURL = URL(string: "https://vbin210327-real.github.io/Readle/")!
}

// MARK: - Profile

/// Your photo and nickname, kept on this device. The photo is saved as a small square JPEG.
@MainActor
final class ProfileStore: ObservableObject {
    static let shared = ProfileStore()
    @Published private(set) var photo: UIImage?
    @Published var name: String { didSet { UserDefaults.standard.set(name, forKey: Self.nameKey) } }
    private static let nameKey = "readle.profile.name"
    private static var fileURL: URL { URL.applicationSupportDirectory.appending(path: "Profile/avatar.jpg") }

    private init() {
        name = UserDefaults.standard.string(forKey: Self.nameKey) ?? ""
        if let data = try? Data(contentsOf: Self.fileURL) { photo = UIImage(data: data) }
    }

    /// Saves the part of the photo inside `crop` (in the image's points) as a 600-pixel square.
    func setPhoto(_ image: UIImage, crop: CGRect) -> Bool {
        let side: CGFloat = 600
        let available = min(crop.width, crop.height, image.size.width, image.size.height)
        guard available.isFinite, available > 0, crop.midX.isFinite, crop.midY.isFinite else { return false }
        // The scroll view can still be bouncing when the user taps 完成.
        let left = min(max(crop.midX - available / 2, 0), image.size.width - available)
        let top = min(max(crop.midY - available / 2, 0), image.size.height - available)
        let scale = side / available
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let square = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            image.draw(in: CGRect(x: -left * scale, y: -top * scale,
                                  width: image.size.width * scale, height: image.size.height * scale))
        }
        guard let jpeg = square.jpegData(compressionQuality: 0.85) else { return false }
        do {
            try FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try jpeg.write(to: Self.fileURL, options: .atomic)
        } catch { return false }
        photo = square
        return true
    }

    /// Reads a picked photo, upright and no larger than 2048 pixels, so huge camera images stay light.
    nonisolated static func loadPicked(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    func removePhoto() {
        try? FileManager.default.removeItem(at: Self.fileURL)
        photo = nil
    }
}

/// Photos fill the circle edge to edge. The white ring belongs to the empty placeholder.
struct AvatarView: View {
    @ObservedObject private var profile = ProfileStore.shared
    let size: CGFloat

    var body: some View {
        let ring = max(2, (size * 0.075).rounded())
        Group {
            if let photo = profile.photo {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                Color(white: 0.92)
                    .overlay {
                        OutlineFigure()
                            .stroke(Color(white: 0.6), style: StrokeStyle(lineWidth: max(1.2, size * 0.032), lineCap: .round))
                            .frame(width: size * 0.44, height: size * 0.44)
                            .offset(y: size * 0.03)
                    }
                    .frame(width: size - ring * 2, height: size - ring * 2)
                    .clipShape(Circle())
                    .padding(ring)
                    .background(.white, in: Circle())
            }
        }
        .accessibilityHidden(true)
    }
}

/// The empty avatar: a thin line-drawn head and shoulders, plain and neutral.
private struct OutlineFigure: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width, h = rect.height
        path.addEllipse(in: CGRect(x: rect.minX + w * 0.32, y: rect.minY + h * 0.06, width: w * 0.36, height: w * 0.36))
        path.move(to: CGPoint(x: rect.minX + w * 0.1, y: rect.maxY))
        path.addArc(center: CGPoint(x: rect.midX, y: rect.maxY), radius: w * 0.4,
                    startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        return path
    }
}

/// The top of 我的: tap the photo to choose or remove it; the nickname is optional.
private struct ProfileHeader: View {
    @ObservedObject private var profile = ProfileStore.shared
    @State private var pick: PhotosPickerItem?
    @State private var choosing = false
    @State private var failed = false
    @State private var editing: PickedPhoto?

    var body: some View {
        HStack(spacing: 16) {
            Group {
                // No photo yet: straight to the picker. With one: change or remove it.
                if profile.photo == nil {
                    Button { choosing = true } label: { AvatarView(size: 76) }
                        .buttonStyle(.plain)
                } else {
                    Menu {
                        Button { choosing = true } label: { Label("从相册选择", systemImage: "photo.on.rectangle") }
                        Button(role: .destructive) { profile.removePhoto() } label: { Label("移除头像", systemImage: "trash") }
                    } label: { AvatarView(size: 76) }
                }
            }
            .accessibilityLabel(profile.photo == nil ? "添加头像" : "更换头像")
            TextField("设置昵称", text: $profile.name)
                .font(.title3.weight(.semibold))
                .submitLabel(.done)
                .onChange(of: profile.name) { _, name in if name.count > 20 { profile.name = String(name.prefix(20)) } }
        }
        .padding(.horizontal, 4)
        .photosPicker(isPresented: $choosing, selection: $pick, matching: .images)
        .onChange(of: pick) { _, item in
            guard let item else { return }
            Task {
                let data = try? await item.loadTransferable(type: Data.self)
                let image = await Task.detached { data.flatMap(ProfileStore.loadPicked) }.value
                if let image { editing = PickedPhoto(image: image) } else { failed = true }
                pick = nil
            }
        }
        .fullScreenCover(item: $editing) { picked in
            AvatarCropView(image: picked.image) { crop in
                if !profile.setPhoto(picked.image, crop: crop) { failed = true }
                editing = nil
            } cancel: { editing = nil }
        }
        .alert("无法使用这张照片", isPresented: $failed) { Button("知道了", role: .cancel) {} }
    }
}

private struct PickedPhoto: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// Move and scale: the photo sits behind a circular window; drag and pinch it into place, then
/// 完成 keeps exactly what is inside the circle. Panning and zooming are iOS's own scroll view, so
/// the pinch follows the fingers and the photo can never leave an empty edge inside the circle.
private struct AvatarCropView: View {
    let image: UIImage
    let done: (CGRect) -> Void
    let cancel: () -> Void
    @State private var scroller = CropScroller()

    var body: some View {
        ZStack {
            GeometryReader { geo in
                let diameter = CropScroller.diameter(in: geo.size)
                let circle = CGRect(x: (geo.size.width - diameter) / 2, y: (geo.size.height - diameter) / 2,
                                    width: diameter, height: diameter)
                ZStack {
                    CropScrollView(image: image, scroller: scroller)
                    Path { path in
                        path.addRect(CGRect(origin: .zero, size: geo.size))
                        path.addEllipse(in: circle)
                    }
                    .fill(Color.black.opacity(0.62), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)
                    Circle()
                        .strokeBorder(Color.white.opacity(0.85), lineWidth: 1)
                        .frame(width: diameter, height: diameter)
                        .position(x: circle.midX, y: circle.midY)
                        .allowsHitTesting(false)
                }
            }
            .ignoresSafeArea()
            VStack {
                Text("移动和缩放").font(.headline).padding(.top, 16)
                Spacer()
                HStack {
                    Button("取消", action: cancel)
                    Spacer()
                    Button("完成") { if let crop = scroller.crop() { done(crop) } }.fontWeight(.semibold)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 20)
            }
            .foregroundStyle(.white)
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
    }
}

/// Holds the scroll view so 完成 can read where the photo ended up.
@MainActor
private final class CropScroller {
    weak var view: CropScrollContent?
    static func diameter(in size: CGSize) -> CGFloat { max(1, min(size.width, size.height) - 48) }
    func crop() -> CGRect? { view?.crop() }
}

private struct CropScrollView: UIViewRepresentable {
    let image: UIImage
    let scroller: CropScroller

    func makeUIView(context: Context) -> CropScrollContent {
        let view = CropScrollContent(image: image)
        scroller.view = view
        return view
    }

    func updateUIView(_ view: CropScrollContent, context: Context) {}
}

/// A scroll view whose zoom and insets keep the circle (centred, `diameter` wide) always inside the
/// photo: at the smallest zoom the photo just covers the circle, and the insets let any part of it
/// be brought under the circle but no further.
private final class CropScrollContent: UIScrollView, UIScrollViewDelegate {
    private let imageView: UIImageView
    private var laidOutFor: CGSize = .zero

    init(image: UIImage) {
        imageView = UIImageView(image: image)
        super.init(frame: .zero)
        delegate = self
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        bouncesZoom = true
        backgroundColor = .black
        imageView.frame = CGRect(origin: .zero, size: image.size)
        addSubview(imageView)
        contentSize = image.size
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != laidOutFor, bounds.width > 0, let size = imageView.image?.size, size.width > 0, size.height > 0 else { return }
        laidOutFor = bounds.size
        let diameter = CropScroller.diameter(in: bounds.size)
        let fill = max(diameter / size.width, diameter / size.height)
        minimumZoomScale = fill
        maximumZoomScale = fill * 5
        zoomScale = fill
        let inset = UIEdgeInsets(top: (bounds.height - diameter) / 2, left: (bounds.width - diameter) / 2,
                                 bottom: (bounds.height - diameter) / 2, right: (bounds.width - diameter) / 2)
        contentInset = inset
        // Start centred on the photo.
        contentOffset = CGPoint(x: (contentSize.width - bounds.width) / 2, y: (contentSize.height - bounds.height) / 2)
    }

    /// The circle, in the photo's own points.
    func crop() -> CGRect? {
        guard zoomScale > 0 else { return nil }
        let diameter = CropScroller.diameter(in: bounds.size)
        let origin = CGPoint(x: contentOffset.x + contentInset.left, y: contentOffset.y + contentInset.top)
        return CGRect(x: origin.x / zoomScale, y: origin.y / zoomScale,
                      width: diameter / zoomScale, height: diameter / zoomScale)
    }
}
