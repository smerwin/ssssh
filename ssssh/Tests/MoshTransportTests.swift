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

    /// Regression test for the actual bug: `HostBytes` is a real
    /// framebuffer-to-framebuffer diff (confirmed by reading mosh's own
    /// `Complete::diff_from`, see `equivalentSince`'s doc comment on
    /// `MoshTransport`), not a slice of one giant append-only output log.
    /// A previous version of this code tried to reconcile a resend
    /// anchored on an older, still-retained baseline by comparing
    /// cumulative byte *lengths* across messages and feeding the assumed
    /// "new tail" -- which happened to reconstruct the right answer for
    /// this exact append-only-shaped fixture, but corrupted real output
    /// against any program whose diffs aren't simple prefix extensions of
    /// each other (confirmed in production against Claude Code's CLI over
    /// Mosh). The sound behavior is to drop a resend anchored outside the
    /// range of states provably identical to the current screen, not to
    /// guess at how it overlaps -- so already-delivered content must stay
    /// exactly as delivered, with nothing appended from the dropped resend.
    @Test("A late resend anchored on a since-diverged baseline is dropped, not merged into already-delivered content")
    func staleBaselineResendIsDroppedNotMerged() throws {
        let key = MoshSessionKey.generateRandomForTesting()
        let transport = MoshTransport(host: "127.0.0.1", port: 60001, sessionKey: key)
        let serverSession = MoshSession(key: key)

        var fed: [UInt8] = []
        transport.onOutput = { fed.append(contentsOf: $0) }

        // Establishes baseline 0 -> 5, delivering "ABCDE".
        transport.handleIncoming(try hostDatagram(session: serverSession, sequence: 0, oldNum: 0, newNum: 5, hostBytes: Array("ABCDE".utf8)))
        // Real forward progress via a *different*, more recent anchor, 5 -> 10.
        transport.handleIncoming(try hostDatagram(session: serverSession, sequence: 1, oldNum: 5, newNum: 10, hostBytes: Array("FGHIJ".utf8)))
        // A late resend, still anchored on the *original* baseline 0 -- no
        // longer provably the current screen's framebuffer, since a real
        // (non-empty) diff was already applied on top of it. Must be
        // dropped whole, not partially merged.
        transport.handleIncoming(try hostDatagram(session: serverSession, sequence: 2, oldNum: 0, newNum: 12, hostBytes: Array("ABCDEFGHIJKL".utf8)))

        #expect(String(decoding: fed, as: UTF8.self) == "ABCDEFGHIJ")
    }

    /// A same-baseline sibling resent under a fresh `new_num`, whether
    /// byte-identical or carrying different content, is likewise dropped
    /// once the baseline it's anchored on is no longer provably the
    /// current screen -- see `staleBaselineResendIsDroppedNotMerged`.
    /// Nothing about the *original* content already fed should change.
    @Test("A same-baseline sibling after real content was already applied is dropped, not re-fed or merged")
    func sameBaselineSiblingAfterRealContentIsDropped() throws {
        let key = MoshSessionKey.generateRandomForTesting()
        let transport = MoshTransport(host: "127.0.0.1", port: 60001, sessionKey: key)
        let serverSession = MoshSession(key: key)

        var fed: [UInt8] = []
        transport.onOutput = { fed.append(contentsOf: $0) }

        transport.handleIncoming(try hostDatagram(session: serverSession, sequence: 0, oldNum: 0, newNum: 5, hostBytes: Array("ABCDE".utf8)))
        // A redundant tick resending the identical diff under a fresh new_num.
        transport.handleIncoming(try hostDatagram(session: serverSession, sequence: 1, oldNum: 0, newNum: 6, hostBytes: Array("ABCDE".utf8)))
        // A sibling carrying different content, still anchored on the same stale baseline.
        transport.handleIncoming(try hostDatagram(session: serverSession, sequence: 2, oldNum: 0, newNum: 8, hostBytes: Array("ABCDEFG".utf8)))

        #expect(String(decoding: fed, as: UTF8.self) == "ABCDE")
    }

    /// Regression test for the original bug this dedup logic was first
    /// built for: a real mosh-server pipelines, so a content-free
    /// (empty-diff) tick and a real-content tick can both arrive anchored
    /// on the *same* reference before either is acked. Since the empty
    /// tick's framebuffer is identical to its reference's, that reference
    /// must stay valid for the real-content sibling that follows it --
    /// dropping it would silently lose genuine output (confirmed against a
    /// real mosh-server: exactly this shape for a login-banner burst).
    @Test("A real-content sibling following an empty sibling on the same baseline is still applied in full")
    func realContentSiblingAfterEmptySiblingIsApplied() throws {
        let key = MoshSessionKey.generateRandomForTesting()
        let transport = MoshTransport(host: "127.0.0.1", port: 60001, sessionKey: key)
        let serverSession = MoshSession(key: key)

        var fed: [UInt8] = []
        transport.onOutput = { fed.append(contentsOf: $0) }

        // Content-free tick: framebuffer at state 1 is identical to state 0's.
        transport.handleIncoming(try hostDatagram(session: serverSession, sequence: 0, oldNum: 0, newNum: 1, hostBytes: []))
        // Real content, still anchored on the original reference (0), which
        // is still provably equivalent to the current screen (state 1).
        transport.handleIncoming(try hostDatagram(session: serverSession, sequence: 1, oldNum: 0, newNum: 2, hostBytes: Array("banner".utf8)))

        #expect(String(decoding: fed, as: UTF8.self) == "banner")
    }
}
