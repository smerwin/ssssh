import SwiftUI
import SwiftTerm

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

    private var theme: TerminalTheme {
        TerminalTheme(rawValue: themeRawValue) ?? .crtGreen
    }

    var body: some View {
        ZStack {
            TerminalHostView(connection: connection, theme: theme)
                // Only ignore the device's own bottom safe area (home
                // indicator) so the terminal can extend under it -- but
                // NOT the keyboard's safe area, which would otherwise let
                // the software keyboard cover the bottom of the terminal.
                .ignoresSafeArea(.container, edges: .bottom)

            if theme.showsScanlines {
                ScanlineOverlay()
                    .allowsHitTesting(false)
            }

            switch connection.state {
            case .connecting:
                StatusBanner(text: "Connecting…", tint: SwiftUI.Color.secondary)
            case .failed(let message):
                StatusBanner(text: message, tint: SwiftUI.Color.red)
            case .disconnected:
                StatusBanner(text: "Disconnected", tint: SwiftUI.Color.secondary)
            case .connected:
                EmptyView()
            }
        }
        .background(theme.background)
        .navigationTitle(connection.host.nickname)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct StatusBanner: View {
    let text: String
    let tint: SwiftUI.Color

    var body: some View {
        VStack {
            Text(text)
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

    func makeUIView(context: Context) -> SwiftTerm.TerminalView {
        let view = terminalViewStore.controller(for: connection).view
        applyTheme(to: view)
        return view
    }

    func updateUIView(_ uiView: SwiftTerm.TerminalView, context: Context) {
        applyTheme(to: uiView)
    }

    private func applyTheme(to view: SwiftTerm.TerminalView) {
        view.nativeBackgroundColor = UIColor(theme.background)
        view.nativeForegroundColor = UIColor(theme.foreground)
    }
}
