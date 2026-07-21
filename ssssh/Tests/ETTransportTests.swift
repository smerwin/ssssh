import Foundation
import Testing
@testable import ssssh

/// `ETTransport`'s protocol-sequencing logic (the `ConnectRequest`/
/// `ConnectResponse` handshake, the `InitialPayload`/`InitialResponse`
/// exchange, and the reconnect `SequenceHeader`/`CatchupBuffer` recovery
/// handshake) is verified against a **real, unmodified `etserver`** in a
/// throwaway Docker container -- including a genuine ~15-second network
/// blackout (via `iptables DROP` inside the container) that forces a real
/// reconnect through the full recovery path -- not with mocks here. See
/// CLAUDE.md's Eternal Terminal section, "What's implemented" under
/// "Recommended scope for a first pass", for what that live run covered
/// and the real ordering bug it caught (an earlier version called
/// `writer.revive(connected: true)` before `writer.recover(...)` had run,
/// violating `recover()`'s own "must run while disconnected" invariant --
/// a mistake only a real reconnect against live infrastructure surfaced,
/// not a hand-crafted unit test). This file only covers the one piece of
/// `ETTransport` that's pure logic, independent of any socket.
struct ETTransportTests {
    @Test("onError fires at most once per transport instance")
    func onErrorFiresAtMostOnce() {
        let transport = ETTransport(host: "127.0.0.1", port: 2022, id: "test-id", passkeyBytes: Array(repeating: 0, count: 32))
        var fireCount = 0
        transport.onError = { _ in fireCount += 1 }

        transport.reportFatalError(ETTransport.TransportError.missingInitialResponse)
        transport.reportFatalError(ETTransport.TransportError.missingInitialResponse)
        transport.reportFatalError(ETTransport.TransportError.unknownPacketHeader(99))

        #expect(fireCount == 1)
    }

    @Test("A later onError handler assignment doesn't get a second call after the first has already fired")
    func laterHandlerAssignmentDoesNotRefire() {
        let transport = ETTransport(host: "127.0.0.1", port: 2022, id: "test-id", passkeyBytes: Array(repeating: 0, count: 32))
        transport.reportFatalError(ETTransport.TransportError.missingInitialResponse)

        var fired = false
        transport.onError = { _ in fired = true }
        transport.reportFatalError(ETTransport.TransportError.unknownPacketHeader(1))

        #expect(!fired)
    }

    /// A rejected reconnect (e.g. a real wifi/5G handoff reported in
    /// production, rejected with `invalidKey`/"Client is not registered")
    /// gets bounded retries with backoff rather than tearing the session
    /// down on the very first rejection -- see `consecutiveReconnectFailures`'
    /// doc comment on `ETTransport` for the full reasoning. The first retry
    /// stays immediate (a real handoff usually recovers on that first
    /// attempt), then backs off exponentially, capped at 30s -- deliberately
    /// not gated on a `nextAllowedRebuildAttempt`-style timestamp the way
    /// `MoshTransport.rebuildBackoff` is, since `ETTransport` has no
    /// periodic heartbeat/path-monitor drumbeat to rely on for a later
    /// retry once a gate would let one through.
    @Test("reconnectBackoff stays immediate on the first failure, then grows and caps at 30s")
    func reconnectBackoffGrowsAndCaps() {
        #expect(ETTransport.reconnectBackoff(forFailureCount: 1) == 0)
        #expect(ETTransport.reconnectBackoff(forFailureCount: 2) == 2)
        #expect(ETTransport.reconnectBackoff(forFailureCount: 3) == 4)
        #expect(ETTransport.reconnectBackoff(forFailureCount: 4) == 8)
        #expect(ETTransport.reconnectBackoff(forFailureCount: 5) == 16)
        #expect(ETTransport.reconnectBackoff(forFailureCount: 6) == 30)
        #expect(ETTransport.reconnectBackoff(forFailureCount: 100) == 30)
    }

    @Test("reconnectBackoff treats non-positive counts as the first, immediate attempt")
    func reconnectBackoffHandlesNonPositiveCounts() {
        #expect(ETTransport.reconnectBackoff(forFailureCount: 0) == 0)
        #expect(ETTransport.reconnectBackoff(forFailureCount: -1) == 0)
    }
}
