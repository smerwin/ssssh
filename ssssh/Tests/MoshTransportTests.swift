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

    /// Regression test for a real production bug: a genuinely
    /// still-unavailable network (e.g. iOS suspending networking while the
    /// app is backgrounded, not just one stale socket) let each
    /// freshly-rebuilt connection fail again just as fast as the last,
    /// cascading through the whole `maxConsecutiveRebuildFailures` budget
    /// within milliseconds -- reported directly as a Mosh session still
    /// dying with "NWError 89" when the phone sleeps. The fix spaces
    /// consecutive attempts out with a growing backoff, mirroring
    /// `SSHConnection`'s own reconnect delay shape.
    @Test("Rebuild backoff grows exponentially per consecutive failure, capped at 30s, starting immediate")
    func rebuildBackoffGrowsAndCaps() {
        #expect(MoshTransport.rebuildBackoff(forFailureCount: 1) == 1)
        #expect(MoshTransport.rebuildBackoff(forFailureCount: 2) == 2)
        #expect(MoshTransport.rebuildBackoff(forFailureCount: 3) == 4)
        #expect(MoshTransport.rebuildBackoff(forFailureCount: 4) == 8)
        #expect(MoshTransport.rebuildBackoff(forFailureCount: 5) == 16)
        #expect(MoshTransport.rebuildBackoff(forFailureCount: 6) == 30)
        #expect(MoshTransport.rebuildBackoff(forFailureCount: 100) == 30)
    }

    @Test("Rebuild backoff never returns a negative or zero delay even for a failure count of zero")
    func rebuildBackoffHandlesNonPositiveCounts() {
        #expect(MoshTransport.rebuildBackoff(forFailureCount: 0) == 1)
        #expect(MoshTransport.rebuildBackoff(forFailureCount: -1) == 1)
    }

    /// Builds an encrypted, authenticated "toClient" datagram carrying one
    /// `HostBytes` instruction, exactly what a real `mosh-server` would
    /// send -- lets these tests drive `MoshTransport.handleIncoming`
    /// directly with a specific, hand-picked sequence of state transitions
    /// instead of needing a real server to (maybe, nondeterministically)
    /// reproduce one.
    private func hostDatagram(session: MoshSession, sequence: UInt64, oldNum: UInt64, newNum: UInt64, hostBytes: [UInt8]) throws -> [UInt8] {
        var inner = MoshProtobuf.Writer()
        inner.writeBytes(field: 4, value: hostBytes, omitIfEmpty: false)
        var instructionWriter = MoshProtobuf.Writer()
        instructionWriter.writeBytes(field: 2, value: inner.bytes, omitIfEmpty: false)
        var messageWriter = MoshProtobuf.Writer()
        messageWriter.writeBytes(field: 1, value: instructionWriter.bytes, omitIfEmpty: false)

        var transportInstruction = MoshTransportInstruction()
        transportInstruction.oldNum = oldNum
        transportInstruction.newNum = newNum
        transportInstruction.throwawayNum = oldNum
        transportInstruction.diff = messageWriter.bytes

        let fragments = try MoshFragmenter().makeFragments(for: transportInstruction, mtu: 1000)
        return session.encrypt(direction: .toClient, sequence: sequence, timestamp: 0, timestampReply: 0, payload: fragments[0].serialize())
    }

    /// Regression test for a real gap in the original same-baseline-only
    /// sibling fix: `HostBytes` is literal terminal output bytes (see
    /// CLAUDE.md's "append-only insight"), so a diff "since old_num" is
    /// really just a suffix of the *same* overall append-only output
    /// stream -- meaning a resend anchored on an *older*, still-retained
    /// baseline can validly carry content that overlaps with content
    /// already delivered via a *different*, more recently reached
    /// baseline, exactly the way a real mosh-server's pipelining can
    /// produce. Tracking "what's been fed for old_num X" alone (the
    /// original fix, for same-baseline siblings only) has no way to
    /// detect that cross-baseline overlap and re-renders the middle
    /// section a second time.
    @Test("A late resend anchored on an older, still-retained baseline doesn't re-feed content already delivered via a newer baseline")
    func crossBaselineResendDoesNotDuplicateContent() throws {
        let key = MoshSessionKey.generateRandomForTesting()
        let transport = MoshTransport(host: "127.0.0.1", port: 60001, sessionKey: key)
        let serverSession = MoshSession(key: key)

        var fed: [UInt8] = []
        transport.onOutput = { fed.append(contentsOf: $0) }

        // Establishes baseline 0 -> 5, delivering "ABCDE".
        transport.handleIncoming(try hostDatagram(session: serverSession, sequence: 0, oldNum: 0, newNum: 5, hostBytes: Array("ABCDE".utf8)))
        // Real forward progress via a *different*, more recent anchor, 5 -> 10.
        transport.handleIncoming(try hostDatagram(session: serverSession, sequence: 1, oldNum: 5, newNum: 10, hostBytes: Array("FGHIJ".utf8)))
        // A late resend, still anchored on the *original* baseline 0 (still
        // within the retained window), recomputed fresh to now cover all
        // the way to 12 -- exactly what a real mosh-server's
        // assumed_receiver_state pipelining can produce.
        transport.handleIncoming(try hostDatagram(session: serverSession, sequence: 2, oldNum: 0, newNum: 12, hostBytes: Array("ABCDEFGHIJKL".utf8)))

        #expect(String(decoding: fed, as: UTF8.self) == "ABCDEFGHIJKL")
    }

    /// The original bug this dedup logic was built for: a same-baseline
    /// sibling resent under a fresh `new_num` with identical or extended
    /// content must still only feed its new tail, not the whole thing
    /// again.
    @Test("A same-baseline sibling with extended content only feeds its new tail")
    func sameBaselineSiblingOnlyFeedsNewTail() throws {
        let key = MoshSessionKey.generateRandomForTesting()
        let transport = MoshTransport(host: "127.0.0.1", port: 60001, sessionKey: key)
        let serverSession = MoshSession(key: key)

        var fed: [UInt8] = []
        transport.onOutput = { fed.append(contentsOf: $0) }

        transport.handleIncoming(try hostDatagram(session: serverSession, sequence: 0, oldNum: 0, newNum: 5, hostBytes: Array("ABCDE".utf8)))
        // A redundant tick resending the identical diff under a fresh new_num.
        transport.handleIncoming(try hostDatagram(session: serverSession, sequence: 1, oldNum: 0, newNum: 6, hostBytes: Array("ABCDE".utf8)))
        // A sibling extending further.
        transport.handleIncoming(try hostDatagram(session: serverSession, sequence: 2, oldNum: 0, newNum: 8, hostBytes: Array("ABCDEFG".utf8)))

        #expect(String(decoding: fed, as: UTF8.self) == "ABCDEFG")
    }
}
