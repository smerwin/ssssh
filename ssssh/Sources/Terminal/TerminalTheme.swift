import SwiftUI

/// Visual themes for the terminal view. `crtGreen` is the default look
/// described in the README; `highContrast` is the accessibility alternative.
enum TerminalTheme: String, CaseIterable {
    case crtGreen
    case highContrast

    var background: Color {
        switch self {
        case .crtGreen: return Color.black
        case .highContrast: return Color.black
        }
    }

    var foreground: Color {
        switch self {
        case .crtGreen: return Color(red: 0.2, green: 1.0, blue: 0.4)
        case .highContrast: return Color.white
        }
    }

    /// Whether to render the subtle scanline/glow overlay.
    var showsScanlines: Bool {
        self == .crtGreen
    }
}
