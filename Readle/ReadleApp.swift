import SwiftUI

@main
struct ReadleApp: App {
    @StateObject private var membership = Membership.shared
    @StateObject private var library = LibraryStore()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.system.rawValue
    var body: some Scene {
        WindowGroup {
            LibraryView(store: library)
                .tint(Palette.accent)
                .preferredColorScheme(AppAppearance(rawValue: appearance)?.scheme)
                .environmentObject(membership)
                .fullScreenCover(isPresented: $membership.showPaywall) { MembershipOfferView(access: membership) }
                .task { await library.start() }
                .task { await membership.start(); await library.activate() }
                .onChange(of: membership.isPro) { _, pro in
                    if pro { Task { await library.activate() } } else if BookAudioPreparer.shared.running { BookAudioPreparer.shared.pause() }
                }
                #if DEBUG
                .task {
                    // Test-only: -ReadlePaywallPreview opens the paywall (with sample prices) at launch.
                    if ProcessInfo.processInfo.arguments.contains("-ReadlePaywallPreview") { membership.showPaywall = true }
                }
                .task {
                    guard membership.allows(.listening), ProcessInfo.processInfo.arguments.contains("-ReadleBenchmark") else { return }
                    await HeartEngine.shared.benchmark { line in await MainActor.run { BookAudioLog.write(line) } }
                }
                #endif
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await membership.start(); await library.activate() } }
                }
                .onOpenURL { url in
                    // The share sheet's "打开句读院" link: just collect what it queued.
                    if url.scheme == "readle-share" { Task { await library.activate() } }
                    else { Task { await library.importBook(url) } }
                }
        }
    }
}
