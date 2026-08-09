import SwiftUI
import UIKit

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

    /// The theme actually rendered, given the persisted raw value from
    /// `@AppStorage` and whether iOS's own Settings > Accessibility >
    /// Increase Contrast is on.
    ///
    /// Increased contrast forces High Contrast regardless of the user's
    /// manual picker choice in Settings -- someone who's already told the
    /// system "I need more contrast everywhere" shouldn't have to separately
    /// discover a second, app-specific setting to get it here. Shared by
    /// `TerminalSessionView` (the live terminal) and `SettingsView` (the
    /// text-size preview) so the two can't drift apart.
    static func resolved(rawValue: String, increasedContrast: Bool) -> TerminalTheme {
        if increasedContrast { return .highContrast }
        return TerminalTheme(rawValue: rawValue) ?? .crtGreen
    }
}

/// The terminal's base text size, in points, before iOS's own Dynamic Type
/// scaling is applied on top of it (see `scaledSize(baseSize:contentSizeCategory:)`).
///
/// Two things set it, both writing the same `AppSettingsKeys.terminalFontSize`
/// default: the slider in `SettingsView`, and pinch-to-zoom on the terminal
/// itself (`TerminalSessionController.handlePinch`). It's deliberately one
/// app-wide value rather than per-session -- a size someone pinched to on one
/// host is the size they want everywhere, and it's the same knob the slider
/// shows, so the two can never disagree about "the" current size.
///
/// Lives alongside `TerminalTheme` because it's the same kind of thing: a
/// persisted, user-facing knob for how the terminal looks.
enum TerminalFontSize {
    /// Small enough to fit a genuinely wide layout (a 132-column `top`, a
    /// side-by-side diff) on a phone, without going so small that the
    /// resulting cell grid stops being legible at all.
    static let minimum: Double = 8
    /// Large enough to be usable as a low-vision accommodation on its own,
    /// *before* Dynamic Type multiplies it further -- at the largest
    /// accessibility content sizes this ends up substantially bigger again.
    static let maximum: Double = 32
    /// The size the terminal used unconditionally before it was adjustable,
    /// so an existing install that never touches either control keeps
    /// exactly the text size it already had.
    static let standard: Double = 14
    /// Half-point granularity: fine enough that a pinch feels continuous
    /// rather than notched, coarse enough that the slider lands on round
    /// values and two nearly-identical sizes never both get persisted.
    static let step: Double = 0.5

    static func clamped(_ size: Double) -> Double {
        min(max(size, minimum), maximum)
    }

    /// Clamped, and rounded to the nearest `step`. Every size that reaches
    /// the terminal or `UserDefaults` goes through here, so a pinch's raw
    /// continuous scale can't persist something like 17.328125 pt.
    static func snapped(_ size: Double) -> Double {
        clamped((size / step).rounded() * step)
    }

    /// "14 pt" / "13.5 pt" -- for the Settings readout and the slider's
    /// VoiceOver value, which would otherwise announce a bare number with no
    /// unit.
    static func description(of size: Double) -> String {
        let snappedSize = snapped(size)
        if snappedSize == snappedSize.rounded() {
            return "\(Int(snappedSize)) pt"
        }
        return "\(snappedSize) pt"
    }

    /// `baseSize` scaled by the same `UIFontMetrics` mechanism the semantic
    /// SwiftUI text styles used elsewhere in the app rely on, so the system
    /// text size (including "Larger Accessibility Sizes") reaches the
    /// terminal too rather than only every other screen.
    ///
    /// The user's own base size and the system's scaling factor deliberately
    /// compose rather than override each other: the system setting stays the
    /// sane default it always was, and the slider/pinch move up or down
    /// *from* it.
    @MainActor
    static func scaledSize(baseSize: Double, contentSizeCategory: UIContentSizeCategory) -> Double {
        let traits = UITraitCollection(preferredContentSizeCategory: contentSizeCategory)
        let scaled = UIFontMetrics(forTextStyle: .body).scaledValue(for: CGFloat(clamped(baseSize)), compatibleWith: traits)
        return Double(scaled)
    }

    /// The actual font handed to `SwiftTerm.TerminalView.font`. SwiftTerm has
    /// no Dynamic Type awareness of its own, so all of the scaling has to
    /// happen here.
    @MainActor
    static func scaledFont(baseSize: Double, contentSizeCategory: UIContentSizeCategory) -> UIFont {
        let size = scaledSize(baseSize: baseSize, contentSizeCategory: contentSizeCategory)
        return UIFont.monospacedSystemFont(ofSize: CGFloat(size), weight: .regular)
    }
}

extension DynamicTypeSize {
    /// Maps SwiftUI's `DynamicTypeSize` to the `UIContentSizeCategory`
    /// `UIFontMetrics` expects, so scaling is driven by the environment
    /// value SwiftUI already tracks rather than depending on a plain
    /// `UIView`'s own trait-collection propagation timing.
    var uiContentSizeCategory: UIContentSizeCategory {
        switch self {
        case .xSmall: return .extraSmall
        case .small: return .small
        case .medium: return .medium
        case .large: return .large
        case .xLarge: return .extraLarge
        case .xxLarge: return .extraExtraLarge
        case .xxxLarge: return .extraExtraExtraLarge
        case .accessibility1: return .accessibilityMedium
        case .accessibility2: return .accessibilityLarge
        case .accessibility3: return .accessibilityExtraLarge
        case .accessibility4: return .accessibilityExtraExtraLarge
        case .accessibility5: return .accessibilityExtraExtraExtraLarge
        @unknown default: return .large
        }
    }
}
