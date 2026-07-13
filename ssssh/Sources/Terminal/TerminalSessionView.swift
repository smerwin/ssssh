import SwiftUI
import SwiftTerm

/// Hosts a live SSH session in a SwiftTerm `TerminalView`. The view can be
/// pushed, popped, and pushed again for the same `SSHConnection` -- the
/// connection itself is owned by `SessionManager` and outlives this view.
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

private struct TerminalHostView: UIViewRepresentable {
    let connection: SSHConnection
    let theme: TerminalTheme

    func makeUIView(context: Context) -> SwiftTerm.TerminalView {
        let view = SwiftTerm.TerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        context.coordinator.attach(view: view, connection: connection)
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

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    /// Kept separate from `Coordinator` because conforming a single class
    /// to both `UIGestureRecognizerDelegate` and `TerminalViewDelegate`
    /// makes the compiler infer the whole type as main-actor-isolated,
    /// which then conflicts with `TerminalViewDelegate`'s nonisolated
    /// requirements ("conformance ... crosses into main actor-isolated
    /// code"). A standalone delegate object sidesteps that entirely.
    private final class SwipeSimultaneousRecognitionDelegate: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        private weak var connection: SSHConnection?
        private weak var terminalView: SwiftTerm.TerminalView?
        private var swipeDelegate: SwipeSimultaneousRecognitionDelegate?

        @MainActor
        func attach(view: SwiftTerm.TerminalView, connection: SSHConnection) {
            self.connection = connection
            self.terminalView = view
            connection.onOutput = { [weak view] bytes in
                view?.feed(byteArray: bytes[...])
            }

            // Swipe down to dismiss the keyboard and use the freed-up space
            // as a taller terminal; swipe up to bring the keyboard back.
            // Allowed to recognize alongside the scroll view's own pan
            // gesture so a quick swipe isn't swallowed by scrolling.
            let swipeDelegate = SwipeSimultaneousRecognitionDelegate()
            self.swipeDelegate = swipeDelegate

            let swipeDown = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipeDown))
            swipeDown.direction = .down
            swipeDown.delegate = swipeDelegate
            view.addGestureRecognizer(swipeDown)

            let swipeUp = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipeUp))
            swipeUp.direction = .up
            swipeUp.delegate = swipeDelegate
            view.addGestureRecognizer(swipeUp)
        }

        @objc @MainActor private func handleSwipeDown() {
            _ = terminalView?.resignFirstResponder()
        }

        @objc @MainActor private func handleSwipeUp() {
            _ = terminalView?.becomeFirstResponder()
        }

        func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            let bytes = Array(data)
            Task { @MainActor [connection] in
                connection?.send(bytes)
            }
        }

        func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
            Task { @MainActor [connection] in
                connection?.resize(cols: newCols, rows: newRows)
            }
        }

        func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
        func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
        func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {}
        func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
    }
}
