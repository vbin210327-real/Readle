import SwiftUI
import StoreKit

enum ReadlePlan: String, CaseIterable, Identifiable {
    case monthly, yearly, lifetime
    static let subscriptions: [Self] = [.monthly, .yearly]
    var id: String { "com.linfanbin.readle.pro." + rawValue }
    var title: String {
        switch self { case .monthly: "月度"; case .yearly: "年度"; case .lifetime: "终身" }
    }
}

@MainActor
final class Membership: ObservableObject {
    static let shared = Membership()
    @Published private(set) var isPro: Bool
    /// The plan that currently gives 高级版.
    @Published private(set) var plan: ReadlePlan?
    @Published private(set) var expiredPlan: ReadlePlan?
    @Published private(set) var translationsRemaining: Int
    @Published var showPaywall = false
    @Published private(set) var products: [Product] = []
    @Published private(set) var yearlyTrial = false
    @Published private(set) var busy = false
    @Published var message: String?
    private let cacheKey = "readle.pro.verifiedThrough"
    private let translationAllowance = TranslationAllowance()
    private var updates: Task<Void, Never>?
    private var subscriptionUpdates: Task<Void, Never>?
    private var expiration: Task<Void, Never>?
    private var revision = 0

    private init() {
        isPro = (UserDefaults.standard.object(forKey: "readle.pro.verifiedThrough") as? Date ?? .distantPast) > Date()
        translationsRemaining = translationAllowance.remaining
    }

    func start() async {
        if updates == nil {
            updates = Task {
                for await result in StoreKit.Transaction.updates {
                    guard case .verified(let transaction) = result,
                          ReadlePlan.allCases.contains(where: { $0.id == transaction.productID }) else { continue }
                    await refresh()
                    await transaction.finish()
                }
            }
        }
        if subscriptionUpdates == nil {
            subscriptionUpdates = Task {
                for await status in Product.SubscriptionInfo.Status.updates {
                    guard case .verified(let transaction) = status.transaction,
                          ReadlePlan.subscriptions.contains(where: { $0.id == transaction.productID }) else { continue }
                    await refresh()
                }
            }
        }
        await refresh()
    }

    private func refresh() async {
        #if DEBUG && targetEnvironment(simulator)
        // A launch argument can preview either expired subscription without changing StoreKit.
        if let value = UserDefaults.standard.string(forKey: "ReadleExpiredPreview"),
           let preview = ReadlePlan(rawValue: value), ReadlePlan.subscriptions.contains(preview) {
            expiration?.cancel()
            expiredPlan = preview
            plan = nil
            isPro = false
            return
        }
        #endif
        revision += 1
        let snapshot = revision
        var through = Date.distantPast
        var best: ReadlePlan?
        for await result in StoreKit.Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  transaction.revocationDate == nil, !transaction.isUpgraded,
                  let plan = ReadlePlan.allCases.first(where: { $0.id == transaction.productID }) else { continue }
            if plan == .lifetime { through = .distantFuture; best = .lifetime; continue }
            let status = await transaction.subscriptionStatus
            var end = transaction.expirationDate ?? .distantPast
            if let status, status.state == .inGracePeriod,
               case .verified(let renewal) = status.renewalInfo, let grace = renewal.gracePeriodExpirationDate {
                end = max(end, grace)
            }
            if end > through {
                through = end
                best = plan
            }
        }
        #if DEBUG
        // Simulator check of the Pro screens (3D shelf) without a purchase.
        if ProcessInfo.processInfo.arguments.contains("-ReadleProPreview") { through = .distantFuture; best = .lifetime }
        #endif
        let active = through > Date()
        let expired = active ? nil : await latestExpiredSubscription()
        guard snapshot == revision else { return }
        expiration?.cancel()
        expiredPlan = expired
        plan = active ? best : nil
        isPro = active
        UserDefaults.standard.set(through, forKey: cacheKey)
        ImportAllowance.shared?.set(through, forKey: ImportAllowance.proThroughKey)
        if isPro, through != .distantFuture {
            expiration = Task {
                do { try await Task.sleep(for: .seconds(max(0, through.timeIntervalSinceNow))) } catch { return }
                await refresh()
            }
        }
    }

    /// Expired subscriptions are absent from currentEntitlements. Look up the previously
    /// purchased plans in StoreKit so the renewal screen also works after relaunch.
    private func latestExpiredSubscription() async -> ReadlePlan? {
        var latest: (plan: ReadlePlan, date: Date)?
        for plan in ReadlePlan.subscriptions {
            guard case .verified(let transaction)? = await StoreKit.Transaction.latest(for: plan.id),
                  !transaction.isUpgraded, transaction.revocationDate == nil,
                  let date = transaction.expirationDate else { continue }
            let state = await transaction.subscriptionStatus?.state
            if (date <= Date() || state == .expired), date > (latest?.date ?? .distantPast) {
                latest = (plan, date)
            }
        }
        return latest?.plan
    }

    enum Feature {
        case shelf3D, theater, listening
        case importBook(currentCount: Int)
    }

    func allows(_ feature: Feature) -> Bool {
        switch feature {
        case .shelf3D, .theater, .listening:
            return isPro
        case .importBook(let count):
            return ImportAllowance.allows(count: count, pro: isPro)
        }
    }

    @discardableResult
    func require(_ feature: Feature) -> Bool {
        let allowed = allows(feature)
        if !allowed { showPaywall = true }
        return allowed
    }

    func translate(
        sentence: String, context: String, word: Bool = false, onProgress: TranslationService.Progress? = nil
    ) async throws -> String {
        let pro = isPro
        defer {
            let remaining = translationAllowance.remaining
            if translationsRemaining != remaining { translationsRemaining = remaining }
        }
        do {
            return try await translationAllowance.perform(isPro: pro) {
                // Free requests display the result once it is complete and counted.
                try await TranslationService().translate(
                    sentence: sentence, context: context, word: word, onProgress: pro ? onProgress : nil
                )
            }
        } catch TranslationAllowance.LimitError.exhausted {
            showPaywall = true
            throw TranslationAllowance.LimitError.exhausted
        }
    }

    func loadProducts() async {
        message = nil
        do {
            products = try await Product.products(for: ReadlePlan.allCases.map(\.id))
            if let subscription = product(.yearly)?.subscription, let offer = subscription.introductoryOffer,
               offer.paymentMode == .freeTrial, offer.period.unit == .day, offer.period.value * offer.periodCount == 3 {
                yearlyTrial = await subscription.isEligibleForIntroOffer
            } else { yearlyTrial = false }
            if products.count != ReadlePlan.allCases.count { message = "部分方案暂时无法从 App Store 获取。请稍后重试。" }
        } catch { message = error.localizedDescription }
    }
    func product(_ plan: ReadlePlan) -> Product? { products.first { $0.id == plan.id } }

    func purchase(_ plan: ReadlePlan) async {
        guard !busy, let product = product(plan) else { return }
        busy = true; message = nil
        defer { busy = false }
        do {
            switch try await product.purchase() {
            case .success(.verified(let transaction)):
                await refresh()
                await transaction.finish()
                if isPro { showPaywall = false }
            case .success(.unverified): message = "App Store 无法验证这笔购买。"
            case .pending: message = "购买正在等待批准。"
            case .userCancelled: break
            @unknown default: message = "请稍后在 App Store 查看购买状态。"
            }
        } catch { message = error.localizedDescription }
    }

    /// Apple's own sheet for changing or cancelling the subscription.
    func manageSubscriptions() async {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }
        do { try await AppStore.showManageSubscriptions(in: scene) } catch { message = error.localizedDescription }
    }

    func restore() async {
        guard !busy else { return }
        busy = true; message = nil
        defer { busy = false }
        do {
            try await AppStore.sync()
            await refresh()
            if isPro { showPaywall = false } else { message = "当前 Apple 账户没有可恢复的高级版购买。" }
        } catch { message = error.localizedDescription }
    }
}
