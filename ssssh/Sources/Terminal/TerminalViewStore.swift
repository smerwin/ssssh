import SwiftUI
import SwiftTerm

/// Owns the live wiring between one `SSHConnection` and its `SwiftTerm.TerminalView`
/// for as long as the session is open, independent of whether a `TerminalSessionView`
/// currently has it on screen. `TerminalViewStore` creates one of these per connection
/// and keeps it alive across navigation, so `view`'s scrollback and `connection.onOutput`
/// stay intact when the user tabs away and back instead of starting from a blank terminal.
final class TerminalSessionController: NSObject, TerminalViewDelegate {
    let view: SwiftTerm.TerminalView
    private weak var connection: SSHConnection?
    private var swipeDelegate: SwipeSimultaneousRecognitionDelegate?

    @MainActor
    init(connection: SSHConnection) {
        self.view = SwiftTerm.TerminalView(frame: .zero)
        self.connection = connection
        super.init()

        view.terminalDelegate = self
        connection.onOutput = { [weak view] bytes in
            view?.feed(byteArray: bytes[...])
        }

        // Swipe down to page up through scrollback (or, inside an
        // alternate-buffer app like vim/less, forward the real page-up key
        // -- see `TerminalView.pageUp`); swipe up to page back down toward
        // the live output. A discrete one-shot jump is worth having
        // alongside `TerminalView`'s own drag-to-scroll (it's a
        // `UIScrollView`) the same way page-up/page-down keys are worth
        // having alongside a mouse wheel. Allowed to recognize alongside
        // that pan gesture so a quick swipe isn't swallowed by scrolling.
        let swipeDelegate = SwipeSimultaneousRecognitionDelegate()
        self.swipeDelegate = swipeDelegate

        let swipeDown = UISwipeGestureRecognizer(target: self, action: #selector(handlePageUp))
        swipeDown.direction = .down
        swipeDown.delegate = swipeDelegate
        view.addGestureRecognizer(swipeDown)

        let swipeUp = UISwipeGestureRecognizer(target: self, action: #selector(handlePageDown))
        swipeUp.direction = .up
        swipeUp.delegate = swipeDelegate
        view.addGestureRecognizer(swipeUp)
    }

    @objc @MainActor private func handlePageUp() {
        view.pageUp()
    }

    @objc @MainActor private func handlePageDown() {
        view.pageDown()
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
        Task { @MainActor [weak connection] in
            connection?.send(bytes)
        }
    }

    func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
        Task { @MainActor [weak connection] in
            connection?.resize(cols: newCols, rows: newRows)
        }
    }

    func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
    func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
    func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {}
    func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
}

/// Kept separate from `TerminalSessionController` because conforming a single class to
/// both `UIGestureRecognizerDelegate` and SwiftTerm's `TerminalViewDelegate` makes the
/// compiler infer the whole type as main-actor-isolated, which then conflicts with
/// `TerminalViewDelegate`'s nonisolated requirements ("conformance ... crosses into main
/// actor-isolated code"). A standalone delegate object sidesteps that entirely.
private final class SwipeSimultaneousRecognitionDelegate: NSObject, UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
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

    /// Drops controllers for sessions `SessionManager` no longer knows about, so a
    /// closed session's `SwiftTerm.TerminalView` (and its scrollback) can be freed.
    func prune(activeIDs: Set<SSHConnection.ID>) {
        controllers = controllers.filter { activeIDs.contains($0.key) }
    }
}
