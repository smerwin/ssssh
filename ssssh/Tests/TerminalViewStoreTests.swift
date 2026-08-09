import Testing
import Foundation
import SwiftTerm
import UIKit
@testable import ssssh

@MainActor
struct TerminalViewStoreTests {
    @Test func reusesSameControllerAndKeepsOutputWiredAcrossFetches() throws {
        let store = TerminalViewStore()
        let connection = SSHConnection(host: SSHHost(nickname: "test", hostname: "example.com", username: "me"))

        // Simulates a `TerminalSessionView` being pushed, fed some output,
        // then popped (nothing here clears `onOutput` or drops the
        // controller) and pushed again -- the regression this store fixes
        // was a brand-new, blank `SwiftTerm.TerminalView` on every push.
        let firstFetch = store.controller(for: connection)
        connection.onOutput?(Array("first line\r\n".utf8))

        let secondFetch = store.controller(for: connection)
        #expect(firstFetch === secondFetch)
        #expect(firstFetch.view === secondFetch.view)

        // Output delivered between fetches (i.e. while no view was "on
        // screen") must still land in the same, persistent terminal buffer
        // rather than being silently dropped.
        connection.onOutput?(Array("second line\r\n".utf8))
        let terminal = secondFetch.view.getTerminal()
        let text = terminal.getText(start: Position(col: 0, row: 0), end: Position(col: 40, row: 1))
        #expect(text.contains("first line"))
        #expect(text.contains("second line"))
    }

    @Test func pruneDropsControllersForClosedSessions() throws {
        let store = TerminalViewStore()
        let connection = SSHConnection(host: SSHHost(nickname: "test", hostname: "example.com", username: "me"))

        let original = store.controller(for: connection)

        // Session still open: pruning against a set that still contains
        // its id must not throw away the existing controller/scrollback.
        store.prune(activeIDs: [connection.id])
        #expect(store.controller(for: connection) === original)

        // Session closed (id no longer in SessionManager's active set):
        // its controller must be dropped so a later reopen of the same
        // host starts a fresh terminal rather than reusing a stale one.
        store.prune(activeIDs: [])
        let afterClose = store.controller(for: connection)
        #expect(afterClose !== original)
    }
}

@MainActor
struct TerminalSessionControllerFontTests {
    private func makeController() -> TerminalSessionController {
        let connection = SSHConnection(host: SSHHost(nickname: "test", hostname: "example.com", username: "me"))
        return TerminalViewStore().controller(for: connection)
    }

    @Test func applyingABaseSizeScalesTheTerminalFont() {
        let controller = makeController()

        controller.applyFont(baseSize: 20, contentSizeCategory: .large)

        #expect(controller.baseFontSize == 20)
        #expect(controller.view.font.pointSize == CGFloat(TerminalFontSize.scaledSize(baseSize: 20, contentSizeCategory: .large)))
    }

    /// The system text size still reaches the terminal after the base size
    /// became user-adjustable -- the two compose, they don't replace each
    /// other.
    @Test func theSystemTextSizeStillScalesTheChosenBaseSize() {
        let controller = makeController()

        controller.applyFont(baseSize: 14, contentSizeCategory: .large)
        let atDefaultCategory = controller.view.font.pointSize

        controller.applyFont(baseSize: 14, contentSizeCategory: .accessibilityExtraExtraExtraLarge)

        #expect(controller.view.font.pointSize > atDefaultCategory)
        // The *base* size is what the slider and pinch deal in, so it must
        // not absorb the system's scaling factor.
        #expect(controller.baseFontSize == 14)
    }

    /// A pinch scales from the size the gesture started at rather than from
    /// whatever the last `.changed` update left behind, so pinching out and
    /// back lands exactly where it began.
    @Test func pinchingScalesFromTheGestureStartSize() {
        let controller = makeController()
        controller.applyFont(baseSize: 10, contentSizeCategory: .large)

        controller.applyPinch(scale: 1.5, from: 10)
        #expect(controller.baseFontSize == 15)

        controller.applyPinch(scale: 1.2, from: 10)
        #expect(controller.baseFontSize == 12)

        controller.applyPinch(scale: 1.0, from: 10)
        #expect(controller.baseFontSize == 10)
    }

    @Test func pinchingSnapsToTheHalfPointStep() {
        let controller = makeController()

        controller.applyPinch(scale: 1.234_5, from: 14)

        // 14 * 1.2345 == 17.283, which lands on 17.5 rather than being
        // persisted as-is.
        #expect(controller.baseFontSize == 17.5)
    }

    /// An enthusiastic pinch can't leave the terminal at a size there's no
    /// way to pinch back out of.
    @Test func pinchingStopsAtTheSupportedRange() {
        let controller = makeController()

        controller.applyPinch(scale: 100, from: 14)
        #expect(controller.baseFontSize == TerminalFontSize.maximum)

        controller.applyPinch(scale: 0.001, from: 14)
        #expect(controller.baseFontSize == TerminalFontSize.minimum)
    }

    /// SwiftTerm's `font` setter rebuilds its font variants, recomputes the
    /// cell grid (resizing the remote PTY with it) and calls `selectNone()`
    /// on every assignment -- so re-applying the size SwiftUI already
    /// applied, which `updateUIView` does constantly, has to leave the
    /// existing font object alone rather than replacing it with an equal one.
    @Test func reapplyingTheSameSizeLeavesALiveSelectionAlone() {
        let controller = makeController()
        controller.applyFont(baseSize: 18, contentSizeCategory: .large)
        controller.view.feed(text: "hello world\r\n")
        controller.view.selectAll()
        #expect(controller.view.selectionActive)

        // The no-op case `updateUIView` hits constantly.
        controller.applyFont(baseSize: 18, contentSizeCategory: .large)

        #expect(controller.view.selectionActive)
    }

    /// The contrast to the test above, and the reason it can't just always
    /// assign: a *real* size change genuinely does go through SwiftTerm's
    /// `font` setter, which drops the selection along with recomputing the
    /// cell grid.
    @Test func changingTheSizeDoesGoThroughSwiftTermsFontSetter() {
        let controller = makeController()
        controller.applyFont(baseSize: 18, contentSizeCategory: .large)
        controller.view.feed(text: "hello world\r\n")
        controller.view.selectAll()

        controller.applyFont(baseSize: 24, contentSizeCategory: .large)

        #expect(!controller.view.selectionActive)
        #expect(controller.view.font.pointSize == CGFloat(TerminalFontSize.scaledSize(baseSize: 24, contentSizeCategory: .large)))
    }
}

@MainActor
struct TerminalContainerViewTests {
    /// Pushing the same session's terminal a second time (or pushing it
    /// from the Sessions tab after first opening it from Hosts) re-parents
    /// one long-lived `SwiftTerm.TerminalView` between two SwiftUI-managed
    /// containers. The bug this covers: the terminal carried its old
    /// container's frame into the new one and nothing re-laid it out, so it
    /// stayed sized for the space it used to have -- typically too tall,
    /// leaving its bottom rows behind the keyboard accessory bar or the tab
    /// bar until a rotation forced a full layout pass.
    @Test func adoptingFromAnotherContainerReparentsAndResizes() {
        let terminal = SwiftTerm.TerminalView(frame: .zero)

        let first = TerminalContainerView(terminalView: terminal)
        first.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        first.layoutIfNeeded()
        #expect(terminal.superview === first)
        #expect(terminal.frame == first.bounds)

        // The second container is deliberately shorter -- that's the real
        // case, a terminal laid out with no keyboard up moving into a
        // container sized for one that is.
        let second = TerminalContainerView(terminalView: terminal)
        second.frame = CGRect(x: 0, y: 0, width: 390, height: 500)
        second.layoutIfNeeded()

        #expect(terminal.superview === second)
        #expect(terminal.frame == second.bounds)
        #expect(first.subviews.isEmpty)
    }

    /// `updateUIView` re-adopts on every SwiftUI update (a theme change, a
    /// Dynamic Type change, a state banner appearing), so the no-op path
    /// has to leave the hierarchy completely alone rather than churning
    /// `removeFromSuperview()`/`addSubview()` on a live, first-responder
    /// terminal.
    @Test func readoptingTheSameTerminalIsANoOp() {
        let terminal = SwiftTerm.TerminalView(frame: .zero)
        let container = TerminalContainerView(terminalView: terminal)
        container.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        container.layoutIfNeeded()

        container.adopt(terminal)

        #expect(terminal.superview === container)
        #expect(container.subviews.count == 1)
        #expect(container.terminalView === terminal)
    }

    /// A container can also be handed a *different* terminal than the one
    /// it was built with -- `TerminalHostView.updateUIView` always adopts
    /// whatever the store currently vends, which changes after
    /// `TerminalViewStore.prune` drops a closed session's controller.
    @Test func adoptingADifferentTerminalReplacesTheOldOne() {
        let original = SwiftTerm.TerminalView(frame: .zero)
        let replacement = SwiftTerm.TerminalView(frame: .zero)
        let container = TerminalContainerView(terminalView: original)
        container.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        container.layoutIfNeeded()

        container.adopt(replacement)
        container.layoutIfNeeded()

        #expect(container.terminalView === replacement)
        #expect(replacement.superview === container)
        #expect(original.superview == nil)
        #expect(container.subviews.count == 1)
        #expect(replacement.frame == container.bounds)
    }
}
