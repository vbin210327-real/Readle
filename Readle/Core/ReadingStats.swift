import SwiftUI

/// How much you read: seconds spent in the reader, day by day, kept on this device.
@MainActor
final class ReadingStats: ObservableObject {
    static let shared = ReadingStats()

    /// Seconds read per day, keyed "yyyy-MM-dd" in the local calendar.
    @Published private(set) var days: [String: Int]
    /// Books read to the end, by id. Kept even if the book is later removed from the shelf.
    @Published private(set) var finished: Set<String>
    private let key = "readle.stats.secondsByDay"
    private let finishedKey = "readle.stats.finishedBooks"
    /// A day counts toward the streak once you have read at least this long.
    private let streakThreshold = 60

    private init() {
        days = (UserDefaults.standard.dictionary(forKey: key) as? [String: Int]) ?? [:]
        finished = Set(UserDefaults.standard.stringArray(forKey: finishedKey) ?? [])
    }

    func markFinished(_ book: UUID) {
        guard finished.insert(book.uuidString).inserted else { return }
        UserDefaults.standard.set(Array(finished), forKey: finishedKey)
    }

    var finishedCount: Int { finished.count }

    func add(_ seconds: Int, on date: Date = Date()) {
        guard seconds > 0 else { return }
        days[Self.day(date), default: 0] += seconds
        // Keep about two years.
        if days.count > 730, let oldest = days.keys.sorted().first { days[oldest] = nil }
        UserDefaults.standard.set(days, forKey: key)
    }

    var totalSeconds: Int { days.values.reduce(0, +) }

    /// Days in a row with some reading, up to today (or yesterday, if today hasn't started yet).
    var streak: Int {
        var back = (days[Self.day(Date())] ?? 0) >= streakThreshold ? 0 : 1
        var count = 0
        while (days[Self.day(Self.date(daysAgo: back))] ?? 0) >= streakThreshold {
            count += 1
            back += 1
        }
        return count
    }

    private static func date(daysAgo: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
    }

    private static func day(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

/// Counts the time a reader is really on screen with the app in front (not the reader set up out
/// of sight during the dive, and not while the phone is locked or the app is in the background).
struct TracksReadingTime: ViewModifier {
    @Environment(\.readerOnScreen) private var onScreen
    @Environment(\.scenePhase) private var scenePhase
    @State private var started: Date?
    @State private var visible = false

    func body(content: Content) -> some View {
        content
            .onAppear { visible = true; update() }
            .onDisappear { visible = false; update() }
            .onChange(of: scenePhase) { _, _ in update() }
            .onChange(of: onScreen) { _, _ in update() }
    }

    private func update() {
        let counting = visible && onScreen && scenePhase == .active
        if counting, started == nil {
            started = Date()
        } else if !counting, let start = started {
            // A single stretch is capped, in case the screen was simply left on.
            ReadingStats.shared.add(min(Int(Date().timeIntervalSince(start)), 3 * 60 * 60), on: start)
            started = nil
        }
    }
}
