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
    @Environment(\.scenePhase) private var scenePhase

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
        // Returning to a session that was on screen when the app was
        // backgrounded doesn't move any view, so
        // `TerminalContainerView.didMoveToWindow` never fires for it --
        // this is the only signal that case has. See
        // `TerminalSessionController.refreshKeyboardLayout()`.
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            terminalViewStore.refreshKeyboardLayout(for: connection)
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
///
/// What it hands back to SwiftUI, though, is a fresh, disposable
/// `TerminalContainerView` per instantiation -- **not** the persistent
/// terminal itself. Returning the same long-lived `UIView` from
/// `makeUIView` more than once means handing SwiftUI a view that is (or
/// recently was) installed in a different view hierarchy: pushing this
/// screen a second time, or pushing it from the Sessions tab after
/// originally opening it from Hosts, re-parents that view out of one
/// SwiftUI-managed container and into another. UIKit drops the constraints
/// tying it to its old superview when it moves, and the new representable
/// container has none of its own for it, so it keeps whatever frame it
/// happened to have -- typically taller than the space actually available
/// now, which is what leaves the bottom rows of the terminal hidden behind
/// the keyboard accessory bar or the tab bar until something forces a full
/// re-layout (rotating the device, or toggling the keyboard). A throwaway
/// container per push, laying the terminal out itself, keeps that
/// arrangement correct by construction no matter how many times the same
/// terminal is shown or where from.
private struct TerminalHostView: UIViewRepresentable {
    let connection: SSHConnection
    let theme: TerminalTheme
    @Environment(TerminalViewStore.self) private var terminalViewStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func makeUIView(context: Context) -> TerminalContainerView {
        let view = terminalViewStore.controller(for: connection).view
        applyTheme(to: view)
        applyFont(to: view)
        return TerminalContainerView(terminalView: view)
    }

    func updateUIView(_ uiView: TerminalContainerView, context: Context) {
        // Re-adopts on every update, not just at `makeUIView` time: two
        // `TerminalHostView`s can briefly coexist for the same connection
        // (a push animating in while the previous screen animates out), and
        // whichever adopted the terminal last wins. Without this the one
        // left holding an empty container would stay empty.
        uiView.adopt(terminalViewStore.controller(for: connection).view)
        applyTheme(to: uiView.terminalView)
        applyFont(to: uiView.terminalView)
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

/// The disposable `UIView` `TerminalHostView` actually hands to SwiftUI,
/// hosting the session's persistent `SwiftTerm.TerminalView` as its only
/// subview -- see `TerminalHostView`'s doc comment for why the terminal
/// itself is deliberately never returned from `makeUIView`.
///
/// Lays the terminal out by assigning `frame` in `layoutSubviews` rather
/// than with Auto Layout constraints, on purpose. `SwiftTerm.TerminalView`
/// is a `UIScrollView` that manages its own `contentSize`/`contentOffset`
/// (`updateScroller()`), and it's re-parented between containers over a
/// session's life; plain frame assignment has no constraints to leave
/// behind on the way out and no `translatesAutoresizingMaskIntoConstraints`
/// state to keep consistent across those moves. The terminal ends up
/// exactly matching this container's bounds every layout pass, which is the
/// entire contract needed here.
final class TerminalContainerView: UIView {
    private(set) var terminalView: SwiftTerm.TerminalView

    init(terminalView: SwiftTerm.TerminalView) {
        self.terminalView = terminalView
        super.init(frame: .zero)
        adopt(terminalView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Makes `view` this container's hosted terminal, moving it out of
    /// whatever container previously held it. Idempotent -- the common case
    /// (SwiftUI re-running `updateUIView` for a theme or Dynamic Type
    /// change) hits the early return and doesn't disturb the hierarchy.
    func adopt(_ view: SwiftTerm.TerminalView) {
        if view === terminalView, view.superview === self { return }
        if view !== terminalView {
            terminalView.removeFromSuperview()
            terminalView = view
        }
        view.removeFromSuperview()
        addSubview(view)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Assigned unconditionally rather than guarded on a change: a
        // terminal adopted from another container arrives carrying that
        // container's frame, which can happen to equal this one's bounds
        // *size* while still being positioned wrong.
        terminalView.frame = bounds
    }

    /// Covers coming back to this session by navigation (the terminal is
    /// re-parented into a brand new container). The app-returns-from-
    /// background case doesn't move the view at all, so it can't come
    /// through here -- `TerminalSessionView` drives that one off
    /// `scenePhase`. Both end up in
    /// `TerminalSessionController.refreshKeyboardLayout()`, which explains
    /// what this is for.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        let terminal = terminalView
        // Deferred rather than run inline: this fires part-way through
        // UIKit's own layout of the hierarchy this view was just added to,
        // and re-publishing keyboard geometry from inside that pass is
        // exactly the kind of reentrancy that produces a *different*
        // mis-layout. By the time this runs the hierarchy has settled.
        Task { @MainActor [weak terminal] in
            guard let terminal, terminal.isFirstResponder else { return }
            terminal.reloadInputViews()
        }
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
