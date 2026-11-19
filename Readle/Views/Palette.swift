import SwiftUI

/// Black, grey and white only: the book's words carry the color.
enum Palette {
    /// Near-black in light mode, near-white in dark mode.
    static let accent = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.93, alpha: 1) : UIColor(white: 0.11, alpha: 1) })
    static let paper = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.055, alpha: 1) : UIColor.white })
    static let ink = Color.primary
    static let muted = Color.secondary
}

// MARK: - iPad

extension EnvironmentValues {
    /// A full iPad window (or a wide Split View pane): regular in both directions. iPhones, Slide
    /// Over and narrow Split View panes keep the phone layout.
    var roomy: Bool { horizontalSizeClass == .regular && verticalSizeClass == .regular }
}

enum Device {
    static var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
}

/// A hardware-keyboard shortcut with no button of its own on screen. Its title is what iPad shows
/// in the shortcut list when you hold ⌘.
struct KeyCommand {
    let title: String
    let key: KeyEquivalent
    var modifiers: EventModifiers = .command
    var enabled = true
    let action: () -> Void
}

extension View {
    /// Hardware-keyboard shortcuts for this screen (iPad keyboards; also iPhone with a keyboard).
    func keyCommands(_ commands: [KeyCommand]) -> some View {
        background {
            ZStack {
                ForEach(commands.indices, id: \.self) { index in
                    let command = commands[index]
                    Button(command.title, action: command.action)
                        .keyboardShortcut(command.key, modifiers: command.modifiers)
                        .disabled(!command.enabled)
                }
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
