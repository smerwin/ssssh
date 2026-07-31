import Testing
import Foundation
@testable import ssssh

/// `SessionManager.session(for:)` and `reconnectIfNeeded()` both key their
/// reuse-vs-reconnect decision off `isDisconnectedOrFailed` -- worth pinning
/// down directly given how much behavior hangs off it.
struct SSHConnectionStateTests {
    @Test func onlyDisconnectedAndFailedAreConsideredDisconnectedOrFailed() {
        #expect(SSHConnection.State.connecting.isDisconnectedOrFailed == false)
        #expect(SSHConnection.State.connected.isDisconnectedOrFailed == false)
        #expect(SSHConnection.State.disconnected.isDisconnectedOrFailed == true)
        #expect(SSHConnection.State.failed("some error").isDisconnectedOrFailed == true)
        #expect(SSHConnection.State.waitingToReconnect(at: .now).isDisconnectedOrFailed == true)
    }

    @MainActor
    @Test func sendKeepaliveIsANoOpWithoutALiveConnection() {
        // `SessionManager`'s background keepalive timer calls this
        // unconditionally on every connected session; it must be safe to
        // call before a connection ever reaches `.connected` (no writer
        // to send through yet) without crashing or changing state.
        let host = SSHHost(nickname: "test", hostname: "example.com", username: "me")
        let connection = SSHConnection(host: host)

        connection.sendKeepalive()

        #expect(connection.state == .connecting)
    }

    @MainActor
    @Test func resizeRecordsTheTerminalSizeEvenWithNowhereToDeliverIt() {
        // The regression this pins down: `lastKnownSize` was only ever its
        // `defaultTerminalSize` initial value, never assigned by `resize`.
        // Every `sendKeepalive()` therefore sent a real WindowChangeRequest
        // resizing the remote PTY back to 80x24 -- so a session left
        // backgrounded for one keepalive interval came back rendering for a
        // grid the on-screen terminal wasn't using, until a device rotation
        // made SwiftTerm re-report the real size.
        //
        // Recording it with no writer/transport attached is the case that
        // matters, not an artificial one: SwiftTerm reports its size as
        // soon as it's laid out, which is normally well before the SSH
        // handshake finishes.
        let host = SSHHost(nickname: "test", hostname: "example.com", username: "me")
        let connection = SSHConnection(host: host)
        #expect(connection.lastKnownSize.cols == SSHConnection.defaultTerminalSize.cols)
        #expect(connection.lastKnownSize.rows == SSHConnection.defaultTerminalSize.rows)

        connection.resize(cols: 44, rows: 47)

        #expect(connection.lastKnownSize.cols == 44)
        #expect(connection.lastKnownSize.rows == 47)
    }

    @MainActor
    @Test func reassertingAndKeepingAliveBothPreserveTheRecordedSize() {
        // Both re-send `lastKnownSize` by routing back through `resize`,
        // which now writes to that same property -- so they have to be
        // idempotent rather than quietly overwriting it with something else.
        let host = SSHHost(nickname: "test", hostname: "example.com", username: "me")
        let connection = SSHConnection(host: host)
        connection.resize(cols: 100, rows: 30)

        connection.reassertTerminalSize()
        #expect(connection.lastKnownSize.cols == 100)
        #expect(connection.lastKnownSize.rows == 30)

        connection.sendKeepalive()
        #expect(connection.lastKnownSize.cols == 100)
        #expect(connection.lastKnownSize.rows == 30)
    }

    @MainActor
    @Test func degenerateSizesAreRejectedRatherThanRecorded() {
        // A terminal view that hasn't been laid out yet reports a zero
        // size; recording that would make every later re-assert (and the
        // PTY request, which now reads this) ask for a 0-column terminal.
        let host = SSHHost(nickname: "test", hostname: "example.com", username: "me")
        let connection = SSHConnection(host: host)
        connection.resize(cols: 80, rows: 40)

        connection.resize(cols: 0, rows: 0)
        #expect(connection.lastKnownSize.cols == 80)
        #expect(connection.lastKnownSize.rows == 40)

        connection.resize(cols: -1, rows: 10)
        #expect(connection.lastKnownSize.cols == 80)
        #expect(connection.lastKnownSize.rows == 40)
    }
}
