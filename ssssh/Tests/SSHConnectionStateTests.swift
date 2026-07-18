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
}
