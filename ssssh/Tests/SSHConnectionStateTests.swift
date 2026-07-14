import Testing
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
    }
}
