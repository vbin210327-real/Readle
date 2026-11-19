import SwiftUI
import StoreKit

struct MembershipOfferView: View {
    @ObservedObject var access: Membership
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.system.rawValue

    var body: some View {
        Group {
            if let expired = access.expiredPlan {
                RenewalPaywall(access: access, previousPlan: expired)
                    .preferredColorScheme(AppAppearance(rawValue: appearance)?.scheme)
            } else {
                MembershipView(access: access)
            }
        }
        .onChange(of: access.isPro) { _, pro in if pro { dismiss() } }
    }
}

private struct RenewalPaywall: View {
    @ObservedObject var access: Membership
    let previousPlan: ReadlePlan
    @Environment(\.dismiss) private var dismiss
    @State private var selection: ReadlePlan?
    @State private var loading = true

    private var selected: ReadlePlan { selection ?? previousPlan }
    private var canRenew: Bool { !access.busy && access.product(selected) != nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 32) {
                    VStack(spacing: 12) {
                        Text("高级版订阅已到期")
                            .font(.system(.largeTitle, design: .serif).weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                        Text("续订后可继续使用高级版功能")
                            .font(.subheadline)
                            .foregroundStyle(Palette.muted)
                    }
                    .multilineTextAlignment(.center)

                    VStack(spacing: 12) {
                        ForEach(ReadlePlan.subscriptions) { plan in planRow(plan) }
                    }

                    VStack(spacing: 12) {
                        Button {
                            Task { await access.purchase(selected) }
                        } label: {
                            Text(checkoutTitle)
                                .font(.headline)
                                .frame(maxWidth: .infinity, minHeight: 52)
                                .foregroundStyle(Palette.paper)
                                .background(Palette.accent, in: RoundedRectangle(cornerRadius: 16))
                        }
                        .buttonStyle(.plain)
                        .disabled(!canRenew)
                        .opacity(canRenew ? 1 : 0.45)
                        .accessibilityIdentifier("renewSubscription")

                        if let message = access.message {
                            Text(message).font(.footnote).foregroundStyle(Palette.muted)
                                .multilineTextAlignment(.center)
                        }
                        if !loading && access.product(selected) == nil {
                            Button("重新加载方案") { Task { await load() } }
                        }
                    }

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 16) { links }.fixedSize(horizontal: true, vertical: false)
                        VStack(spacing: 4) { links }
                    }
                    .font(.footnote)
                    .foregroundStyle(Palette.muted)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 32)
                .frame(maxWidth: 460)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(Palette.paper.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
                        .keyboardShortcut(.cancelAction)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .tint(Palette.accent)
        .task { await load() }
    }

    private func planRow(_ plan: ReadlePlan) -> some View {
        let isSelected = selected == plan
        let shape = RoundedRectangle(cornerRadius: 16)
        let title = plan == .monthly ? "月订阅" : "年订阅"
        let price = access.product(plan)?.displayPrice ?? (loading ? "—" : "暂不可用")
        return Button { selection = plan } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.system(.title3, design: .serif).weight(.semibold))
                    Text(plan == .yearly && access.yearlyTrial ? "3天免费试用，之后自动续订" : "自动续订，可随时取消")
                        .font(.footnote)
                        .foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 0)
                Text(price).font(.system(.title3, design: .serif).monospacedDigit())
            }
            .padding(20)
            .frame(minHeight: 84)
            .background(isSelected ? Palette.accent.opacity(0.05) : .clear, in: shape)
            .overlay { shape.strokeBorder(Palette.accent.opacity(isSelected ? 1 : 0.22), lineWidth: isSelected ? 1.5 : 1) }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("renewPlan-\(plan.rawValue)")
    }

    private var checkoutTitle: String {
        if access.busy { return "正在处理…" }
        if access.product(selected) == nil { return loading ? "正在获取价格…" : "方案暂不可用" }
        if selected == .yearly && access.yearlyTrial { return "开始免费试用" }
        return "续订高级版"
    }

    @ViewBuilder private var links: some View {
        Button("恢复购买") { Task { await access.restore() } }.disabled(access.busy)
        Link("订阅条款", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
        Link("隐私政策", destination: ReadlePrivacy.policyURL)
            .accessibilityIdentifier("readlePrivacyPolicy")
    }

    private func load() async {
        loading = true
        await access.loadProducts()
        loading = false
    }
}

/// The paywall: a dark, cinematic sheet — a planet's rim of light behind the title, the features
/// compared on a card with a glass "高级版" column, three plans with a 推荐 tab on the yearly
/// plan, and a cut-corner button to start.
///
/// Measurements follow the design reference on a 393 pt wide screen.
struct MembershipView: View {
    @ObservedObject var access: Membership
    @Environment(\.dismiss) private var dismiss
    @State private var selection = ReadlePlan.recommended
    @State private var loadingProducts = true
    /// iPad: the phone-width column floats in the middle of the screen as one block, with the
    /// start button right under it, instead of stretching the button down to the bottom edge.
    @Environment(\.roomy) private var roomy

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        if roomy { Spacer(minLength: 32) }
                        header
                            .background(alignment: .bottomTrailing) {
                                // The horizon rises behind the comparison card, even when the header scrolls.
                                Color.white
                                    .frame(width: 202, height: 160)
                                    .colorEffect(ShaderLibrary.paywallMoon())
                                    .offset(y: 72)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                            }
                        ComparisonCard()
                            .padding(.leading, 18).padding(.trailing, 17)
                            .padding(.top, 28)
                        plans
                            .padding(.top, 33)
                        links
                            .padding(.top, 15)
                        if let message = access.message {
                            Text(message)
                                .font(.system(size: 12.5))
                                .foregroundStyle(Color(white: 0.75))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 40).padding(.top, 16)
                        }
                        disclosureText
                            .padding(.top, 14.5)
                        if roomy {
                            if !access.isPro { checkout.padding(.top, 40) }
                            Spacer(minLength: 32)
                        } else {
                            Spacer(minLength: 28)
                            if !access.isPro { checkout }
                        }
                    }
                    .padding(.bottom, 30)
                    .frame(maxWidth: 430)
                    .frame(maxWidth: .infinity, minHeight: geo.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .background(PaywallBackdrop().ignoresSafeArea())
            .overlay(alignment: .topTrailing) {
                // On iPad the close button sits in the screen's corner, not the column's.
                if roomy { closeButton.padding(.trailing, 20).padding(.top, 12) }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .task { await loadProducts() }
    }

    // MARK: Title

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                if !roomy {
                    closeButton
                        .padding(.trailing, 13)
                        .padding(.top, -9.5)
                }
            }
            .frame(height: 27)
            Text("解锁句读院高级版")
                .font(.system(size: 31.5, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.35), radius: 6, y: 1)
                .padding(.leading, 26)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private var closeButton: some View {
        Button { dismiss() } label: {
            ZStack {
                Circle().fill(Color(white: 0.15))
                Circle().strokeBorder(Color(white: 1, opacity: 0.22), lineWidth: 0.8)
                Image(systemName: "xmark")
                    .font(.system(size: 11.5, weight: .light))
                    .foregroundStyle(Color(white: 0.9))
            }
            .frame(width: 31, height: 31)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .keyboardShortcut(.cancelAction)
        .accessibilityLabel("关闭")
    }

    // MARK: Plans

    private var plans: some View {
        VStack(spacing: 10.5) {
            ForEach(ReadlePlan.featuredOrder) { plan in
                planCard(plan)
                    .padding(.top, plan == .recommended ? 8 : 0)
            }
        }
    }

    private func planCard(_ plan: ReadlePlan) -> some View {
        let selected = selection == plan
        let hero = plan == .recommended
        let hasTrial = plan == .yearly && trialOffered
        return Button {
            withAnimation(.spring(duration: 0.3, bounce: 0.15)) { selection = plan }
        } label: {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(plan.title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                    if hasTrial {
                        Text("3天免费试用")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color(white: 0.86))
                    }
                }
                .offset(y: hasTrial ? 2 : 0)
                .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 16)
                Text(priceText(plan))
                    .font(.system(size: hero ? 19 : 17, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .padding(.leading, 29)
            .padding(.trailing, hero ? 23.8 : 22)
            .frame(height: hero ? 67 : 42.5)
            .background { PlanFrame(plan: plan, selected: selected) }
            .overlay(alignment: .topLeading) {
                if hero { RecommendedTab().offset(x: 9.2, y: -9.5) }
            }
            .padding(.horizontal, hero ? 19.4 : 21.2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(plan.title)，\(priceText(plan))" + (hero ? "，推荐" : "") + (hasTrial ? "，3天免费试用" : ""))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: Links and terms

    private var links: some View {
        HStack(spacing: 0) {
            footerLink("恢复购买") { Task { await access.restore() } }
                .disabled(access.busy)
            separator
            Link(destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!) {
                linkLabel("使用条款")
            }
            separator
            Link(destination: ReadlePrivacy.policyURL) { linkLabel("隐私政策") }
                .accessibilityIdentifier("readlePrivacyPolicy")
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .bottom) {
            if !loadingProducts && access.products.count < ReadlePlan.allCases.count {
                Button("重新加载方案") { Task { await loadProducts() } }
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color(white: 0.8))
                    .offset(y: 30)
                    .disabled(access.busy)
            }
        }
    }

    private var separator: some View {
        Rectangle().fill(Color(white: 1, opacity: 0.32)).frame(width: 1, height: 14)
    }

    private func footerLink(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { linkLabel(title) }
    }

    private func linkLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13.5))
            .foregroundStyle(Color(white: 0.88))
            .frame(width: 84, height: 44)
            .contentShape(Rectangle())
            .hoverEffect(.highlight)
    }

    private var disclosureText: some View {
        Text(disclosure)
            .font(.system(size: 12.5))
            .foregroundStyle(Color(white: 0.6))
            .lineSpacing(4.5)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 48)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Checkout

    private var checkout: some View {
        let canPurchase = access.product(selection) != nil && !access.busy
        return Button {
            Task { await access.purchase(selection) }
        } label: {
            HStack(spacing: 23) {
                Text(checkoutTitle)
                    .font(.system(size: 19, weight: .semibold))
                    .tracking(1.5)
                Image(systemName: "chevron.right.2")
                    .font(.system(size: 14, weight: .light))
                    .foregroundStyle(Color(white: 0.85))
            }
            .foregroundStyle(.white)
            .offset(x: 9.6)
            .frame(maxWidth: .infinity)
            .frame(height: 48.5)
            .background { StartButtonFrame() }
            .opacity(canPurchase ? 1 : 0.45)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .hoverEffect(.lift)
        .keyboardShortcut(.defaultAction)
        .disabled(!canPurchase)
        .padding(.horizontal, 36)
    }

    private var checkoutTitle: String {
        if access.busy { return "正在处理…" }
        guard access.product(selection) != nil || previewing else {
            return loadingProducts ? "正在获取价格…" : "方案暂不可用"
        }
        switch selection {
        case .yearly: return trialOffered ? "开始免费试用" : "订阅年度高级版"
        case .monthly: return "订阅月度高级版"
        case .lifetime: return "购买终身高级版"
        }
    }

    // MARK: Prices

    private var trialOffered: Bool { access.yearlyTrial || (previewing && access.product(.yearly) == nil) }

    private func displayPrice(_ plan: ReadlePlan) -> String? {
        if let product = access.product(plan) { return product.displayPrice }
        #if DEBUG
        if previewing { return ["monthly": "US$2.99", "yearly": "US$19.99", "lifetime": "US$39.99"][plan.rawValue] }
        #endif
        return nil
    }

    private func priceText(_ plan: ReadlePlan) -> String {
        guard let price = displayPrice(plan) else { return loadingProducts ? "—" : "暂不可用" }
        switch plan {
        case .monthly: return "\(price) / 月"
        case .yearly: return "\(price) / 年"
        case .lifetime: return price
        }
    }

    private var disclosure: String {
        guard let price = displayPrice(selection) else { return "价格以 App Store 显示为准。可在 Apple 账户的订阅设置中取消。" }
        if selection == .lifetime { return "一次性支付 \(price)，永久使用高级版。" }
        return (selection == .yearly && trialOffered ? "免费试用 3 天，之后" : "") +
            "按 \(priceText(selection))自动续订。可在 Apple 账户的订阅设置中取消。"
    }

    /// Debug builds only: `-ReadlePaywallPreview` shows sample prices when the App Store can't be reached.
    private var previewing: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-ReadlePaywallPreview")
        #else
        false
        #endif
    }

    private func loadProducts() async {
        loadingProducts = true
        await access.loadProducts()
        loadingProducts = false
    }

    // MARK: Privacy

}

private extension ReadlePlan {
    static let recommended = ReadlePlan.yearly
    static var featuredOrder: [ReadlePlan] { [.lifetime, .recommended, .monthly] }
}

// MARK: - Comparison card

private struct ComparisonCard: View {
    private struct Row {
        let symbol: AnyView
        let name: String
        let free: String
        let pro: String
        let height: CGFloat
        let nudge: CGFloat
    }

    private let rows: [Row] = [
        Row(symbol: AnyView(BookshelfGlyph()), name: "书架", free: "平面书架", pro: "3D 书架", height: 44.3, nudge: 2.7),
        Row(symbol: AnyView(ReadingGlyph()), name: "阅读", free: "常规模式", pro: "影院模式 · 常规模式", height: 40.1, nudge: 0.6),
        Row(symbol: AnyView(SparkleGlyph()), name: "AI 翻译", free: "次数限制", pro: "不限次数", height: 37.4, nudge: 0.2),
        Row(symbol: AnyView(Image(systemName: "headphones").font(.system(size: 15, weight: .light))), name: "听书", free: "—", pro: "中英朗读", height: 37.3, nudge: 0.3),
        Row(symbol: AnyView(ImportGlyph()), name: "导入", free: "数量限制", pro: "不限数量", height: 43.4, nudge: -3.2),
    ]
    private let headerHeight: CGFloat = 44.5
    private let proWidth: CGFloat = 154.5

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let proX = width - proWidth
            ZStack(alignment: .topLeading) {
                // The card.
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(white: 0.094))
                Rectangle()
                    .fill(LinearGradient(colors: [Color(white: 0.145), Color(white: 0.13)], startPoint: .top, endPoint: .bottom))
                    .frame(height: headerHeight)
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [Color(white: 1, opacity: 0.2), Color(white: 1, opacity: 0.1)],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: 0.8)

                // Free side.
                VStack(spacing: 0) {
                    ZStack(alignment: .leading) {
                        Text("功能").padding(.leading, 20.5)
                        Text("普通版").position(x: 157, y: headerHeight / 2)
                    }
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Color(white: 0.92))
                    .frame(width: width, height: headerHeight)
                    .accessibilityHidden(true)
                    ForEach(rows.indices, id: \.self) { index in
                        let row = rows[index]
                        ZStack(alignment: .top) {
                            Rectangle().fill(Color(white: 1, opacity: 0.085)).frame(height: 0.7)
                                .padding(.leading, 19).frame(width: proX - 18.5, alignment: .leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            HStack(spacing: 0) {
                                row.symbol
                                    .foregroundStyle(.white)
                                    .frame(width: 20)
                                    .padding(.leading, 19)
                                Text(row.name)
                                    .font(.system(size: 13.5, weight: .medium))
                                    .foregroundStyle(.white)
                                    .padding(.leading, 13.5)
                                Spacer(minLength: 0)
                            }
                            .frame(maxHeight: .infinity)
                            .offset(y: row.nudge)
                            Text(row.free)
                                .font(.system(size: 13.5))
                                .foregroundStyle(Color(white: 0.56))
                                .frame(width: 100)
                                .frame(maxHeight: .infinity)
                                .offset(y: row.nudge)
                                .position(x: 157, y: row.height / 2)
                        }
                        .frame(height: row.height)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(row.name)，普通版 \(row.free == "—" ? "不支持" : row.free)，高级版 \(row.pro)")
                    }
                }
                .frame(width: width)

                // The glass 高级版 column.
                ProColumn(rows: rows.map { ($0.pro, $0.height, $0.nudge) }, headerHeight: headerHeight)
                    .frame(width: proWidth)
                    .offset(x: proX)
                    .accessibilityHidden(true)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .frame(height: 247)
    }
}

private struct ProColumn: View {
    let rows: [(String, CGFloat, CGFloat)]
    let headerHeight: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        ZStack(alignment: .top) {
            shape.fill(.white)
                .colorEffect(ShaderLibrary.paywallGlass(.boundingRect, .float(Float(headerHeight))))
            shape.strokeBorder(LinearGradient(stops: [
                .init(color: Color(white: 1, opacity: 0.95), location: 0),
                .init(color: Color(white: 1, opacity: 0.62), location: 0.35),
                .init(color: Color(white: 1, opacity: 0.55), location: 0.7),
                .init(color: Color(white: 1, opacity: 0.85), location: 1),
            ], startPoint: .top, endPoint: .bottom), lineWidth: 1.1)
            VStack(spacing: 0) {
                Text("高级版")
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(height: headerHeight)
                ForEach(rows.indices, id: \.self) { index in
                    let (text, height, nudge) = rows[index]
                    ZStack(alignment: .top) {
                        Rectangle()
                            .fill(Color(white: 1, opacity: index == 0 ? 0.2 : 0.11))
                            .frame(height: 0.7)
                            .padding(.leading, 18.5).padding(.trailing, 20)
                        Text(text)
                            .font(.system(size: 13.5))
                            .foregroundStyle(Color(white: 0.96))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                            .padding(.leading, 19.5)
                            .offset(y: nudge)
                    }
                    .frame(height: height)
                }
            }
        }
    }
}

// MARK: - Plan frames

private struct PlanFrame: View {
    let plan: ReadlePlan
    let selected: Bool

    var body: some View {
        if plan == .recommended {
            let shape = Chamfered(topLeading: 9, topTrailing: 9, bottomTrailing: 8.5, bottomLeading: 9)
            shape.fill(.white)
                .colorEffect(ShaderLibrary.featuredPlanSurface(.boundingRect))
                .overlay {
                    shape.strokeBorder(Color(white: selected ? 0.92 : 0.36), lineWidth: selected ? 1.1 : 0.8)
                }
        } else {
            let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
            shape.fill(.white)
                .colorEffect(ShaderLibrary.standardPlanSurface(.boundingRect, .float(plan == .lifetime ? 1 : 0)))
                .overlay {
                    shape.strokeBorder(Color(white: selected ? 0.92 : 0.20), lineWidth: selected ? 1.1 : 0.7)
                }
        }
    }
}

private struct RecommendedTab: View {
    var body: some View {
        Text("推荐")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color(white: 0.12))
            .frame(width: 61.5, height: 17.5)
            .offset(x: -2)
            .background {
                Slanted(slant: 9.5)
                    .fill(LinearGradient(colors: [Color(white: 0.88), Color(white: 0.74)], startPoint: .top, endPoint: .bottom))
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            }
    }
}

// MARK: - The start button

private struct StartButtonFrame: View {
    var body: some View {
        let shape = Chamfered(topLeading: 14.5, topTrailing: 8.5, bottomTrailing: 14, bottomLeading: 9)
        ZStack {
            shape.fill(LinearGradient(colors: [Color(white: 0.125), Color(white: 0.085)], startPoint: .top, endPoint: .bottom))
            shape.fill(LinearGradient(colors: [Color(white: 1, opacity: 0.05), .clear], startPoint: .top, endPoint: .center))
            shape.stroke(Color(white: 1, opacity: 0.82), lineWidth: 1)
            StartButtonHighlights().stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineCap: .square, lineJoin: .miter))
            StartButtonInnerLines().stroke(Color(white: 1, opacity: 0.55), lineWidth: 0.9)
        }
        .shadow(color: Color(white: 1, opacity: 0.12), radius: 8)
    }
}

/// The brighter, thicker runs of the button's edge: round the top-left cut, down the right below
/// its cut, and along the bottom into the bottom-right cut.
private struct StartButtonHighlights: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width, h = rect.height
        path.move(to: CGPoint(x: 0, y: 23))
        path.addLine(to: CGPoint(x: 0, y: 14.5))
        path.addLine(to: CGPoint(x: 14.5, y: 0))
        path.addLine(to: CGPoint(x: 38.7, y: 0))
        path.move(to: CGPoint(x: w, y: 9))
        path.addLine(to: CGPoint(x: w, y: 26.7))
        path.move(to: CGPoint(x: w - 75, y: h))
        path.addLine(to: CGPoint(x: w - 14, y: h))
        path.addLine(to: CGPoint(x: w, y: h - 14))
        return path
    }
}

private struct StartButtonInnerLines: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width, h = rect.height
        path.move(to: CGPoint(x: 8.8, y: 13.8))
        path.addLine(to: CGPoint(x: 18, y: 4.6))
        path.addLine(to: CGPoint(x: 59.5, y: 4.6))
        path.move(to: CGPoint(x: w - 63, y: h - 4.6))
        path.addLine(to: CGPoint(x: w - 18, y: h - 4.6))
        path.addLine(to: CGPoint(x: w - 12, y: h - 10.2))
        return path
    }
}

private struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .brightness(configuration.isPressed ? 0.06 : 0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - Shapes

/// A rectangle with its corners cut off diagonally.
private struct Chamfered: InsettableShape {
    var topLeading: CGFloat, topTrailing: CGFloat, bottomTrailing: CGFloat, bottomLeading: CGFloat
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        var path = Path()
        path.move(to: CGPoint(x: r.minX + topLeading, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX - topTrailing, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX, y: r.minY + topTrailing))
        path.addLine(to: CGPoint(x: r.maxX, y: r.maxY - bottomTrailing))
        path.addLine(to: CGPoint(x: r.maxX - bottomTrailing, y: r.maxY))
        path.addLine(to: CGPoint(x: r.minX + bottomLeading, y: r.maxY))
        path.addLine(to: CGPoint(x: r.minX, y: r.maxY - bottomLeading))
        path.addLine(to: CGPoint(x: r.minX, y: r.minY + topLeading))
        path.closeSubpath()
        return path
    }

    func inset(by amount: CGFloat) -> Chamfered {
        var shape = self
        shape.inset += amount
        return shape
    }
}

/// A parallelogram leaning right, like a tab.
private struct Slanted: Shape {
    let slant: CGFloat
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + slant, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - slant, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Glyphs

/// Three books resting on a shelf.
private struct BookshelfGlyph: View {
    var body: some View {
        Canvas { context, size in
            let scale = size.width / 20
            var path = Path()
            path.addRoundedRect(in: CGRect(x: 2.5 * scale, y: 1 * scale, width: 4.5 * scale, height: 14 * scale),
                                cornerSize: CGSize(width: 1 * scale, height: 1 * scale))
            path.addRoundedRect(in: CGRect(x: 7.1 * scale, y: 4.2 * scale, width: 4.3 * scale, height: 10.8 * scale),
                                cornerSize: CGSize(width: 1 * scale, height: 1 * scale))
            path.move(to: CGPoint(x: 12.2 * scale, y: 4.1 * scale))
            path.addQuadCurve(to: CGPoint(x: 14.5 * scale, y: 3.4 * scale), control: CGPoint(x: 12.9 * scale, y: 3.6 * scale))
            path.addQuadCurve(to: CGPoint(x: 15.5 * scale, y: 4.1 * scale), control: CGPoint(x: 15.2 * scale, y: 3.3 * scale))
            path.addLine(to: CGPoint(x: 18.3 * scale, y: 12.9 * scale))
            path.addQuadCurve(to: CGPoint(x: 17.7 * scale, y: 14 * scale), control: CGPoint(x: 18.5 * scale, y: 13.7 * scale))
            path.addLine(to: CGPoint(x: 15.8 * scale, y: 14.8 * scale))
            path.addQuadCurve(to: CGPoint(x: 14.7 * scale, y: 14.2 * scale), control: CGPoint(x: 15.1 * scale, y: 15 * scale))
            path.addLine(to: CGPoint(x: 11.8 * scale, y: 5.3 * scale))
            path.addQuadCurve(to: CGPoint(x: 12.2 * scale, y: 4.1 * scale), control: CGPoint(x: 11.5 * scale, y: 4.5 * scale))
            path.move(to: CGPoint(x: 0.8 * scale, y: 15.4 * scale))
            path.addLine(to: CGPoint(x: 19.2 * scale, y: 15.4 * scale))
            context.stroke(path, with: .foreground, style: StrokeStyle(lineWidth: 1.1 * scale, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 18, height: 15)
    }
}

/// An open book with two lines on each page.
private struct ReadingGlyph: View {
    var body: some View {
        Canvas { context, size in
            let scale = size.width / 20
            var path = Path()
            path.move(to: CGPoint(x: 1 * scale, y: 2.5 * scale))
            path.addCurve(to: CGPoint(x: 10 * scale, y: 3 * scale),
                          control1: CGPoint(x: 4 * scale, y: 0.3 * scale),
                          control2: CGPoint(x: 7 * scale, y: 0.3 * scale))
            path.addCurve(to: CGPoint(x: 19 * scale, y: 2.5 * scale),
                          control1: CGPoint(x: 13 * scale, y: 0.3 * scale),
                          control2: CGPoint(x: 16 * scale, y: 0.3 * scale))
            path.addLine(to: CGPoint(x: 19 * scale, y: 14 * scale))
            path.addCurve(to: CGPoint(x: 10 * scale, y: 14.7 * scale),
                          control1: CGPoint(x: 16 * scale, y: 12.6 * scale),
                          control2: CGPoint(x: 13 * scale, y: 12.6 * scale))
            path.addCurve(to: CGPoint(x: 1 * scale, y: 14 * scale),
                          control1: CGPoint(x: 7 * scale, y: 12.6 * scale),
                          control2: CGPoint(x: 4 * scale, y: 12.6 * scale))
            path.closeSubpath()
            path.move(to: CGPoint(x: 10 * scale, y: 5.7 * scale))
            path.addLine(to: CGPoint(x: 10 * scale, y: 14.7 * scale))
            for y: CGFloat in [6.3, 9.3] {
                path.move(to: CGPoint(x: 3.5 * scale, y: y * scale))
                path.addLine(to: CGPoint(x: 7.5 * scale, y: y * scale))
                path.move(to: CGPoint(x: 12.5 * scale, y: y * scale))
                path.addLine(to: CGPoint(x: 16.5 * scale, y: y * scale))
            }
            context.stroke(path, with: .foreground, style: StrokeStyle(lineWidth: 1.1 * scale, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 18, height: 15)
    }
}

/// A four-pointed sparkle with curved sides, for AI 翻译.
private struct SparkleGlyph: View {
    var body: some View {
        Canvas { context, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2), r = size.width / 2 - 0.8, k = r * 0.12
            var path = Path()
            path.move(to: CGPoint(x: c.x, y: c.y - r))
            path.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + k, y: c.y - k))
            path.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x + k, y: c.y + k))
            path.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - k, y: c.y + k))
            path.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x - k, y: c.y - k))
            context.stroke(path, with: .foreground, style: StrokeStyle(lineWidth: 1.25, lineJoin: .round))
        }
        .frame(width: 16, height: 16)
    }
}

/// An arrow down into an open tray, for 导入.
private struct ImportGlyph: View {
    var body: some View {
        Canvas { context, size in
            let s = size.width / 16
            var path = Path()
            path.move(to: CGPoint(x: 8 * s, y: 1 * s))
            path.addLine(to: CGPoint(x: 8 * s, y: 10 * s))
            path.move(to: CGPoint(x: 4.3 * s, y: 6.4 * s))
            path.addLine(to: CGPoint(x: 8 * s, y: 10.1 * s))
            path.addLine(to: CGPoint(x: 11.7 * s, y: 6.4 * s))
            path.move(to: CGPoint(x: 1 * s, y: 9 * s))
            path.addLine(to: CGPoint(x: 1 * s, y: 14.5 * s))
            path.addLine(to: CGPoint(x: 15 * s, y: 14.5 * s))
            path.addLine(to: CGPoint(x: 15 * s, y: 9 * s))
            context.stroke(path, with: .foreground, style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 16, height: 16)
    }
}

// MARK: - Backdrop

/// The page beneath the moon and purchase controls.
private struct PaywallBackdrop: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.073)))

            // Light falling across the bottom right, over everything.
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .radialGradient(
                Gradient(colors: [Color(white: 1, opacity: 0.05), .clear]),
                center: CGPoint(x: size.width * 1.05, y: size.height * 0.78), startRadius: 0, endRadius: size.width * 0.9))
        }
    }
}
