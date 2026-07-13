import SwiftUI

/// Visual themes for the terminal view. `crtGreen` is the default look
/// described in the README; `amber` is the classic amber-phosphor
/// alternative; `highContrast` is the accessibility option.
enum TerminalTheme: String, CaseIterable {
    case crtGreen
    case amber
    case highContrast

    var displayName: String {
        switch self {
        case .crtGreen: return "Green CRT"
        case .amber: return "Amber CRT"
        case .highContrast: return "High Contrast"
        }
    }

    var background: Color {
        Color.black
    }

    var foreground: Color {
        switch self {
        case .crtGreen: return Color(red: 0.2, green: 1.0, blue: 0.4)
        case .amber: return Color(red: 1.0, green: 0.75, blue: 0.0)
        case .highContrast: return Color.white
        }
    }

    /// Whether to render the subtle scanline/glow overlay.
    var showsScanlines: Bool {
        self == .crtGreen || self == .amber
    }

    /// Used to tint UI chrome outside the terminal itself (currently the
    /// tab bar's selected-item color) so it matches the active theme.
    /// Deliberately distinct from `foreground`: high contrast's terminal
    /// text is a fixed white-on-black look, but `.primary` adapts to the
    /// system's light/dark appearance so the tab bar (which isn't forced
    /// to a black background) keeps good contrast either way.
    var accentColor: Color {
        switch self {
        case .crtGreen, .amber: return foreground
        case .highContrast: return .primary
        }
    }
}
