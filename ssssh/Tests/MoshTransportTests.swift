import Foundation
import Testing
@testable import ssssh

struct MoshTransportTests {
    /// Regression test for a real production bug: once
    /// `consecutiveRebuildFailures` exceeded its cap, `rebuildConnection`
    /// re-triggered `onError` on *every* subsequent rebuild attempt
    /// (roughly every 3-12s via the heartbeat's silence check) rather than
    /// just once. Each firing reached `SSHConnection`'s post-commit
    /// `onError` handler unconditionally, which fired `finishWithDrop` ->
    /// `onDrop` -> `reconnectWithBackoff` again every time -- confirmed in
    /// production as dozens of concurrent reconnect-and-upgrade-to-Mosh
    /// attempts stacking up for what was really a single dropped session.
    @Test("onError fires at most once per transport instance, no matter how many times an internal error path fires")
    func onErrorFiresAtMostOnce() {
        let transport = MoshTransport(host: "127.0.0.1", port: 60001, sessionKey: MoshSessionKey.generateRandomForTesting())
        var firedCount = 0
        transport.onError = { _ in firedCount += 1 }

        struct DummyError: Error {}
        for _ in 0..<10 {
            transport.reportFatalError(DummyError())
        }

        #expect(firedCount == 1)
    }

    @Test("A later onError handler assignment doesn't get a second call after the first has already fired")
    func onErrorNotCalledAgainAfterReassignment() {
        let transport = MoshTransport(host: "127.0.0.1", port: 60001, sessionKey: MoshSessionKey.generateRandomForTesting())
        struct DummyError: Error {}
        transport.reportFatalError(DummyError())

        var firedAfterReassignment = false
        transport.onError = { _ in firedAfterReassignment = true }
        transport.reportFatalError(DummyError())

        #expect(!firedAfterReassignment)
    }
}
