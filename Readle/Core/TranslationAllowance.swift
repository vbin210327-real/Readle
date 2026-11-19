import Foundation

@MainActor
final class TranslationAllowance {
    enum LimitError: LocalizedError {
        case exhausted
        case inProgress

        var errorDescription: String? {
            switch self {
            case .exhausted: "已用完 100 次免费 AI 翻译和查词额度。"
            case .inProgress: "请等待当前翻译完成后重试。"
            }
        }
    }

    static let limit = 100
    private let defaults: UserDefaults
    private let key = "readle.translation.freeUses"
    private var pending = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var remaining: Int { max(0, Self.limit - max(0, defaults.integer(forKey: key))) }

    func perform(isPro: Bool, operation: () async throws -> String) async throws -> String {
        try Task.checkCancellation()
        if isPro { return try await operation() }
        guard remaining > 0 else { throw LimitError.exhausted }
        guard pending < remaining else { throw LimitError.inProgress }

        // Reserve capacity before suspending so concurrent requests cannot overspend.
        pending += 1
        defer { pending -= 1 }
        let result = try await operation()
        try Task.checkCancellation()
        defaults.set(Self.limit - remaining + 1, forKey: key)
        return result
    }
}
