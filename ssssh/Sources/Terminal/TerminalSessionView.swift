import SwiftUI
import SwiftTerm
import UIKit

/// Hosts a live SSH session in a SwiftTerm `TerminalView`. The view can be
/// pushed, popped, and pushed again for the same `SSHConnection` -- the
/// connection itself is owned by `SessionManager`, and the actual
/// `SwiftTerm.TerminalView` (with its scrollback) is owned by
/// `TerminalViewStore`, so both outlive this view and popping back in later
/// picks up right where the session was left, including any output that
/// arrived while it wasn't on screen.
struct TerminalSessionView: View {
    let connection: SSHConnection
    @AppStorage(AppSettingsKeys.terminalTheme) private var themeRawValue = TerminalTheme.crtGreen.rawValue
    @Environment(TerminalViewStore.self) private var terminalViewStore
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var selectedTheme: TerminalTheme {
        TerminalTheme(rawValue: themeRawValue) ?? .crtGreen
    }

    /// The theme actually rendered. Forces High Contrast whenever iOS's own
    /// Settings > Accessibility > Increase Contrast is on, regardless of the
    /// user's manual picker choice in Settings -- someone who's already told
    /// the system "I need more contrast everywhere" shouldn't have to
    /// separately discover a second, app-specific setting to get it here.
    private var theme: TerminalTheme {
        colorSchemeContrast == .increased ? .highContrast : selectedTheme
    }

    /// Also follows Reduce Transparency, independent of theme -- the
    /// scanline/vignette overlay is a translucency effect and should go
    /// away when the user has asked the system to reduce those everywhere.
    private var showsScanlines: Bool {
        theme.showsScanlines && !reduceTransparency
    }

    var body: some View {
        ZStack {
            TerminalHostView(connection: connection, theme: theme)
                // Only ignore the device's own bottom safe area (home
                // indicator) so the terminal can extend under it -- but
                // NOT the keyboard's safe area, which would otherwise let
                // the software keyboard cover the bottom of the terminal.
                .ignoresSafeArea(.container, edges: .bottom)

            if showsScanlines {
                ScanlineOverlay()
                    .allowsHitTesting(false)
            }

            switch connection.state {
            case .connecting, .disconnected:
                StatusBanner(tint: SwiftUI.Color.secondary) {
                    Text(connection.state.shortStatusText)
                }
            case .failed:
                StatusBanner(tint: SwiftUI.Color.red) {
                    Text(connection.state.shortStatusText)
                }
            case .waitingToReconnect(let date):
                // `Text(_:style:.timer)` counts down to `date` on its own,
                // no manual `Timer` needed -- so the banner shows exactly
                // how long until the next auto-reconnect attempt instead of
                // sitting on a static "Disconnected" with no sign anything
                // is going to happen.
                StatusBanner(tint: SwiftUI.Color.secondary) {
                    Text("Reconnecting in ") + Text(date, style: .timer)
                }
            case .connected:
                EmptyView()
            }
        }
        .background(theme.background)
        .navigationTitle(connection.host.nickname)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    terminalViewStore.toggleKeyboard(for: connection)
                } label: {
                    Label("Toggle Keyboard", systemImage: "keyboard")
                }
            }
        }
        // VoiceOver has no other signal that a background reconnect
        // finished or a session dropped -- these state changes are
        // otherwise purely visual (the StatusBanner above).
        .onChange(of: connection.state) { _, newState in
            announce(newState)
        }
    }

    private func announce(_ state: SSHConnection.State) {
        let message: String?
        switch state {
        case .connecting:
            message = nil
        case .connected:
            message = "Connected to \(connection.host.nickname)"
        case .disconnected:
            message = "Disconnected from \(connection.host.nickname)"
        case .failed(let reason):
            message = "Connection to \(connection.host.nickname) failed: \(reason)"
        case .waitingToReconnect:
            message = "Reconnecting to \(connection.host.nickname)"
        }
        guard let message else { return }
        UIAccessibility.post(notification: .announcement, argument: message)
    }
}

private struct StatusBanner<Content: View>: View {
    let tint: SwiftUI.Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack {
            content
                .font(.footnote)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .foregroundStyle(tint)
                .padding(.top, 8)
            Spacer()
        }
    }
}

/// Thin `UIViewRepresentable` shim -- the actual `SwiftTerm.TerminalView` and its
/// delegate wiring live in `TerminalViewStore`, keyed by connection, so this just
/// fetches (creating on first use) rather than building its own each time it's
/// instantiated.
private struct TerminalHostView: UIViewRepresentable {
    let connection: SSHConnection
    let theme: TerminalTheme
    @Environment(TerminalViewStore.self) private var terminalViewStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func makeUIView(context: Context) -> SwiftTerm.TerminalView {
        let view = terminalViewStore.controller(for: connection).view
        applyTheme(to: view)
        applyFont(to: view)
        return view
    }

    func updateUIView(_ uiView: SwiftTerm.TerminalView, context: Context) {
        applyTheme(to: uiView)
        applyFont(to: uiView)
    }

    private func applyTheme(to view: SwiftTerm.TerminalView) {
        view.nativeBackgroundColor = UIColor(theme.background)
        view.nativeForegroundColor = UIColor(theme.foreground)
    }

    /// SwiftTerm's own default font never responds to the system text-size
    /// setting -- it has no Dynamic Type awareness of its own. Scale it
    /// with the same `UIFontMetrics` mechanism the semantic SwiftUI text
    /// styles used elsewhere in the app rely on, so bumping the system text
    /// size (including "Larger Accessibility Sizes") reaches the terminal
    /// too, not just every other screen.
    private func applyFont(to view: SwiftTerm.TerminalView) {
        let baseFont = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let traits = UITraitCollection(preferredContentSizeCategory: dynamicTypeSize.uiContentSizeCategory)
        view.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: baseFont, compatibleWith: traits)
    }
}

private extension DynamicTypeSize {
    /// Maps SwiftUI's `DynamicTypeSize` to the `UIContentSizeCategory`
    /// `UIFontMetrics` expects, so scaling is driven by the environment
    /// value SwiftUI already tracks rather than depending on this plain
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
