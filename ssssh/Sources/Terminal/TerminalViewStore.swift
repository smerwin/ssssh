import SwiftUI
import SwiftTerm
import UIKit

/// Owns the live wiring between one `SSHConnection` and its `SwiftTerm.TerminalView`
/// for as long as the session is open, independent of whether a `TerminalSessionView`
/// currently has it on screen. `TerminalViewStore` creates one of these per connection
/// and keeps it alive across navigation, so `view`'s scrollback and `connection.onOutput`
/// stay intact when the user tabs away and back instead of starting from a blank terminal.
final class TerminalSessionController: NSObject, TerminalViewDelegate {
    let view: SwiftTerm.TerminalView
    private weak var connection: SSHConnection?
    private var simultaneousDelegate: ScrollPanSimultaneousRecognitionDelegate?
    /// The base (pre-Dynamic-Type) text size currently applied to `view`.
    /// Seeded from the persisted setting rather than from
    /// `TerminalFontSize.standard` so a pinch is scaling from the real
    /// current size even in the (theoretical) case of one landing before
    /// SwiftUI's first `applyFont(baseSize:contentSizeCategory:)`.
    private(set) var baseFontSize = UserDefaults.standard.terminalFontSize
    /// The content size category last handed down from SwiftUI, kept so a
    /// pinch can rebuild the scaled font without needing the environment.
    private var contentSizeCategory: UIContentSizeCategory = .large
    /// The base size the in-flight pinch started from; `nil` whenever no
    /// pinch is in progress.
    private var pinchStartFontSize: Double?
    /// The scaled (post-Dynamic-Type) size last handed to SwiftTerm, so a
    /// redundant re-apply can be skipped -- see `setFont(baseSize:)`. `nil`
    /// until the first one, since SwiftTerm starts on its own 12pt default
    /// rather than on anything this app chose.
    private var appliedScaledSize: Double?
    /// Predictive local echo, active only while `connection.isUsingMosh`
    /// -- see `MoshPredictionEngine`'s doc comment. Always present (rather
    /// than created/torn down with the Mosh upgrade) since it's a no-op
    /// engine with nothing pending whenever `predict` is never called for
    /// it, which keeps this wiring unconditional and simple.
    private let predictionEngine = MoshPredictionEngine()

    @MainActor
    init(connection: SSHConnection) {
        self.view = SwiftTerm.TerminalView(frame: .zero)
        self.connection = connection
        super.init()

        view.terminalDelegate = self
        connection.onOutput = { [weak view, weak self] bytes in
            // Erase any predictions this host output abandons *before*
            // feeding the real bytes, so a stale underlined prediction
            // never lingers past the moment it's known to be wrong -- see
            // MoshPredictionEngine's doc comment.
            if let cleanup = self?.predictionEngine.reconcile(hostBytes: bytes) {
                view?.feed(byteArray: cleanup[...])
            }
            view?.feed(byteArray: bytes[...])
        }

        // SwiftTerm's stock accessory bar has a Tab button but no way to combine
        // it with Shift (see `TerminalAccessoryView`'s doc comment) -- swap in a
        // wrapper that keeps that bar as-is and adds a Shift+Tab button alongside it.
        view.inputAccessoryView = TerminalAccessoryView(terminalView: view)

        // Swipe down to page up through scrollback (or, inside an
        // alternate-buffer app like vim/less, forward the real page-up key
        // -- see `TerminalView.pageUp`); swipe up to page back down toward
        // the live output. A discrete one-shot jump is worth having
        // alongside `TerminalView`'s own drag-to-scroll (it's a
        // `UIScrollView`) the same way page-up/page-down keys are worth
        // having alongside a mouse wheel. Scoped to recognize alongside
        // *only* that scroll pan gesture (not every recognizer on the
        // view) so a quick swipe isn't swallowed by scrolling -- without
        // this scoping, the delegate previously said yes to simultaneous
        // recognition against SwiftTerm's own double-tap and selection-pan
        // gestures too, which let a swipe steal touches from word-select
        // and left stray highlighting behind after paging.
        let simultaneousDelegate = ScrollPanSimultaneousRecognitionDelegate(scrollPanGesture: view.panGestureRecognizer)
        self.simultaneousDelegate = simultaneousDelegate

        let swipeDown = UISwipeGestureRecognizer(target: self, action: #selector(handlePageUp))
        swipeDown.direction = .down
        swipeDown.delegate = simultaneousDelegate
        view.addGestureRecognizer(swipeDown)

        let swipeUp = UISwipeGestureRecognizer(target: self, action: #selector(handlePageDown))
        swipeUp.direction = .up
        swipeUp.delegate = simultaneousDelegate
        view.addGestureRecognizer(swipeUp)

        // Pinch to resize the terminal's text, the same gesture every other
        // iOS text surface uses for it. `TerminalView` is a `UIScrollView`,
        // but SwiftTerm never gives it a zoom-scale range (nothing in
        // `iOSTerminalView.swift` touches `minimumZoomScale`/
        // `maximumZoomScale`/`viewForZooming`, checked against the pinned
        // 1.14.0), so UIScrollView's own pinch recognizer is inert and this
        // isn't competing with anything built in.
        //
        // The scroll pan is capped at a single touch so a two-finger pinch
        // can't drag the scrollback out from under the gesture at the same
        // time: two-finger scrolling is deliberately given up for zooming
        // (one-finger drag-to-scroll and the swipe gestures above are both
        // untouched by this). The simultaneous-recognition delegate still
        // matters for the reverse order: a one-finger drag that's already
        // scrolling when a second finger lands would otherwise block the
        // pinch from ever starting.
        view.panGestureRecognizer.maximumNumberOfTouches = 1
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch))
        pinch.delegate = simultaneousDelegate
        view.addGestureRecognizer(pinch)
    }

    /// Applies `baseSize`, scaled for `contentSizeCategory`, to the terminal.
    /// Driven by SwiftUI (`TerminalHostView.updateUIView`) whenever the
    /// stored size or the system text size changes.
    ///
    /// Deliberately a no-op while a pinch is in flight: SwiftUI re-runs
    /// `updateUIView` for reasons that have nothing to do with text size (a
    /// status banner appearing, a theme change, a re-adopted container), and
    /// letting one of those land mid-gesture would snap the font back to the
    /// persisted size under the user's fingers.
    @MainActor func applyFont(baseSize: Double, contentSizeCategory: UIContentSizeCategory) {
        guard pinchStartFontSize == nil else { return }
        self.contentSizeCategory = contentSizeCategory
        setFont(baseSize: baseSize)
    }

    /// The pinch handler's own math, factored out so it can be exercised
    /// without synthesizing a `UIPinchGestureRecognizer` (whose `state` and
    /// `scale` can't be driven from a test).
    @MainActor func applyPinch(scale: Double, from startSize: Double) {
        setFont(baseSize: TerminalFontSize.snapped(startSize * scale))
    }

    /// The single place `view.font` is assigned.
    ///
    /// The assignment is guarded on the rendered size actually changing
    /// because SwiftTerm's `font` setter does real work every single time:
    /// it rebuilds the bold/italic variants, recomputes the cell grid
    /// (`resetFont()`, which resizes the terminal and so sends a
    /// window-change request to the remote), and calls `selectNone()`.
    /// Unguarded -- which is what this path used to be -- an unrelated
    /// SwiftUI update was enough to drop a selection the user was in the
    /// middle of making.
    ///
    /// The guard compares the size we last applied rather than the
    /// `UIFont`s themselves, so it depends on nothing about how UIKit
    /// vends or compares font objects.
    @MainActor private func setFont(baseSize: Double) {
        let clamped = TerminalFontSize.clamped(baseSize)
        baseFontSize = clamped
        let scaled = TerminalFontSize.scaledSize(baseSize: clamped, contentSizeCategory: contentSizeCategory)
        guard scaled != appliedScaledSize else { return }
        appliedScaledSize = scaled
        view.font = TerminalFontSize.scaledFont(baseSize: clamped, contentSizeCategory: contentSizeCategory)
    }

    @objc @MainActor private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            // Scaling from the size the gesture started at (rather than
            // resetting `gesture.scale` each update) keeps a pinch that goes
            // out and back landing exactly where it began.
            pinchStartFontSize = baseFontSize
        case .changed:
            guard let start = pinchStartFontSize else { return }
            applyPinch(scale: Double(gesture.scale), from: start)
        case .ended, .cancelled, .failed:
            guard pinchStartFontSize != nil else { return }
            pinchStartFontSize = nil
            // Persisted once the gesture settles rather than on every
            // `.changed`: this is the app-wide terminal text size (the
            // Settings slider reads and writes the same key), so writing it
            // continuously would churn `UserDefaults` -- and, through
            // `@AppStorage`, re-render every view observing it -- dozens of
            // times per pinch. A cancelled or failed gesture still persists,
            // since whatever it last applied is what's on screen.
            UserDefaults.standard.set(baseFontSize, forKey: AppSettingsKeys.terminalFontSize)
        default:
            break
        }
    }

    @objc @MainActor private func handlePageUp() {
        view.pageUp()
    }

    @objc @MainActor private func handlePageDown() {
        view.pageDown()
    }

    /// Asks UIKit to re-measure the input accessory bar and re-publish the
    /// keyboard's frame, without disturbing the keyboard itself.
    ///
    /// Called when this session comes back on screen -- from the background
    /// (`TerminalSessionView`'s `scenePhase` handler) or from another
    /// screen (`TerminalContainerView.didMoveToWindow`). Returning with the
    /// keyboard already up doesn't reliably re-publish its geometry, and
    /// SwiftUI's keyboard-avoidance inset is driven entirely by those
    /// notifications: if none arrives, the terminal is laid out as though
    /// there were no keyboard and no accessory bar beneath it, so its
    /// bottom rows sit underneath both. That's the state the user was
    /// having to clear by hand by hiding and re-showing the keyboard with
    /// the toolbar button -- which works only because dismissing and
    /// presenting the keyboard is itself what forces the geometry to be
    /// republished. This does the same thing without the round trip
    /// through an empty screen.
    ///
    /// A no-op when the terminal isn't first responder: with no keyboard on
    /// screen there's no stale inset to correct.
    @MainActor func refreshKeyboardLayout() {
        guard view.isFirstResponder else { return }
        view.reloadInputViews()
    }

    /// Toolbar button for showing/hiding the keyboard -- the swipe
    /// gestures above no longer do this (repurposed for scrollback
    /// paging now that this button covers it), and it's the only way to
    /// reach the toggle under VoiceOver regardless, since single-finger
    /// swipes are reserved system-wide for VoiceOver's own navigation.
    @MainActor func toggleKeyboard() {
        if view.isFirstResponder {
            _ = view.resignFirstResponder()
        } else {
            _ = view.becomeFirstResponder()
        }
    }

    func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
        let bytes = Array(data)
        Task { @MainActor [weak connection, weak view, predictionEngine] in
            if let connection, connection.isUsingMosh, let view, !view.getTerminal().isCurrentBufferAlternate,
               let preview = predictionEngine.predict(keystroke: bytes) {
                view.feed(byteArray: preview[...])
            }
            connection?.send(bytes)
        }
    }

    func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
        Task { @MainActor [weak connection, weak view, predictionEngine] in
            // A resize invalidates any assumption predictions were making
            // about cursor position -- see MoshPredictionEngine's doc
            // comment on why this app doesn't model the terminal itself
            // and so can't reconcile through a reflow.
            if let cleanup = predictionEngine.reset() {
                view?.feed(byteArray: cleanup[...])
            }
            connection?.resize(cols: newCols, rows: newRows)
        }
    }

    func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
    func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
    func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {}
    func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
}

/// Lets the terminal's added gestures (scrollback swipes, pinch-to-zoom) run
/// alongside the scroll view's own pan -- and *only* that one, so a swipe or a
/// pinch never steals touches from SwiftTerm's own double-tap and
/// selection-pan gestures.
///
/// Kept separate from `TerminalSessionController` because conforming a single class to
/// both `UIGestureRecognizerDelegate` and SwiftTerm's `TerminalViewDelegate` makes the
/// compiler infer the whole type as main-actor-isolated, which then conflicts with
/// `TerminalViewDelegate`'s nonisolated requirements ("conformance ... crosses into main
/// actor-isolated code"). A standalone delegate object sidesteps that entirely.
private final class ScrollPanSimultaneousRecognitionDelegate: NSObject, UIGestureRecognizerDelegate {
    private weak var scrollPanGesture: UIPanGestureRecognizer?

    init(scrollPanGesture: UIPanGestureRecognizer) {
        self.scrollPanGesture = scrollPanGesture
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        otherGestureRecognizer === scrollPanGesture
    }
}

/// Keeps one `TerminalSessionController` (and its `SwiftTerm.TerminalView`) alive per
/// `SSHConnection` for the life of the session. `TerminalSessionView` fetches through
/// here instead of creating its own terminal view, so popping back to the Sessions list
/// and pushing the same session again reuses the same view -- scrollback and any output
/// that arrived while the session wasn't on screen are still there.
@MainActor
@Observable
final class TerminalViewStore {
    private var controllers: [SSHConnection.ID: TerminalSessionController] = [:]

    func controller(for connection: SSHConnection) -> TerminalSessionController {
        if let existing = controllers[connection.id] {
            return existing
        }
        let controller = TerminalSessionController(connection: connection)
        controllers[connection.id] = controller
        return controller
    }

    func toggleKeyboard(for connection: SSHConnection) {
        controller(for: connection).toggleKeyboard()
    }

    func refreshKeyboardLayout(for connection: SSHConnection) {
        controller(for: connection).refreshKeyboardLayout()
    }

    /// Drops controllers for sessions `SessionManager` no longer knows about, so a
    /// closed session's `SwiftTerm.TerminalView` (and its scrollback) can be freed.
    func prune(activeIDs: Set<SSHConnection.ID>) {
        controllers = controllers.filter { activeIDs.contains($0.key) }
    }
}
