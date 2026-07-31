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
