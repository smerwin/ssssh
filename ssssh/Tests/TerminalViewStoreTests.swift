import Testing
import Foundation
import SwiftTerm
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
