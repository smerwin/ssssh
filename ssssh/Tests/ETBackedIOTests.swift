import Foundation
import Testing
@testable import ssssh

/// Mirrors the scenarios in EternalTerminal's own
/// `test/unit_tests/BackedIOTest.cpp` (`BackedReader`/`BackedWriter`
/// round-trip, in-order recovery, revive seeding the replay queue, the
/// disconnected-buffer cap, and the connected trim-to-64MB behavior) --
/// same test names in spirit, adapted to this port's "produce bytes,
/// don't own the socket" split (see `ETBackedIO.swift`'s doc comments).
struct ETBackedIOTests {
    private static let key = (0..<32).map { UInt8($0 * 3 &+ 7) }

    @Test("Writer and reader round-trip a single packet, and the reader's sequence number advances")
    func roundTrip() throws {
        let writer = ETBackedWriter(cryptoStream: ETCryptoStream(key: Self.key, directionByte: 0), connected: true)
        let reader = ETBackedReader(cryptoStream: ETCryptoStream(key: Self.key, directionByte: 0))

        let input = ETPacket(encrypted: false, header: 42, payload: Array("hello backed io".utf8))
        guard case .ready(let bytes) = writer.write(input) else {
            Issue.record("expected .ready when connected")
            return
        }

        let streamReader = ETPacketStreamReader()
        let packets = try streamReader.feed(bytes)
        #expect(packets.count == 1)
        let output = try reader.consumeLivePacket(packets[0])
        #expect(output.header == 42)
        #expect(output.payload == Array("hello backed io".utf8))
        #expect(reader.sequenceNumber == 1)
    }

    @Test("recover() replays buffered messages in original order")
    func recoversInOrder() throws {
        let writer = ETBackedWriter(cryptoStream: ETCryptoStream(key: Self.key, directionByte: 0), connected: true)
        let decryptStream = ETCryptoStream(key: Self.key, directionByte: 0)

        let first = ETPacket(encrypted: false, header: 1, payload: Array("first".utf8))
        let second = ETPacket(encrypted: false, header: 2, payload: Array("second".utf8))
        _ = writer.write(first)
        _ = writer.write(second)

        writer.revive(connected: false)
        let recovered = try writer.recover(lastValidSequenceNumber: 0)
        #expect(recovered.count == 2)

        var recoveredFirst = try ETPacket.parse(recovered[0])
        recoveredFirst.payload = try decryptStream.decrypt(recoveredFirst.payload)
        #expect(recoveredFirst.header == 1)
        #expect(recoveredFirst.payload == Array("first".utf8))

        var recoveredSecond = try ETPacket.parse(recovered[1])
        recoveredSecond.payload = try decryptStream.decrypt(recoveredSecond.payload)
        #expect(recoveredSecond.header == 2)
        #expect(recoveredSecond.payload == Array("second".utf8))
    }

    @Test("revive() seeds the reader's replay queue and credits the sequence number immediately")
    func reviveSeedsLocalBuffer() throws {
        // Two independent streams sharing a key+direction, matching real
        // usage: the peer's own writer encrypted this packet with its
        // stream (simulated here), and the reader decrypts with its own,
        // in lockstep only because both advance their nonce once each.
        let peerWriterStream = ETCryptoStream(key: Self.key, directionByte: 0)
        let reader = ETBackedReader(cryptoStream: ETCryptoStream(key: Self.key, directionByte: 0))

        var cached = ETPacket(encrypted: false, header: 7, payload: Array("cached-payload".utf8))
        cached.payload = peerWriterStream.encrypt(cached.payload)
        cached.encrypted = true

        reader.revive(replayPackets: [cached.serialize()])
        // Sequence number is credited at revive time, before anything is
        // actually drained -- matches BackedReader::revive exactly.
        #expect(reader.sequenceNumber == 1)

        let fromCache = try reader.nextReplayPacket()
        #expect(fromCache?.header == 7)
        #expect(fromCache?.payload == Array("cached-payload".utf8))
        #expect(reader.sequenceNumber == 1)
        #expect(try reader.nextReplayPacket() == nil)
    }

    @Test("write() buffers up to the disconnect cap, then reports skipped; revive() resets it")
    func buffersWhenDisconnectedUntilLimit() {
        let writer = ETBackedWriter(cryptoStream: ETCryptoStream(key: Self.key, directionByte: 0), connected: true)
        let chunk = [UInt8](repeating: 0x78, count: 1024 * 1024) // 1MB

        // Deliver some data while connected; this must not eat into the
        // disconnect headroom.
        for i in 0..<8 {
            guard case .ready = writer.write(ETPacket(encrypted: false, header: UInt8(i), payload: chunk)) else {
                Issue.record("expected .ready while connected")
                return
            }
        }

        writer.revive(connected: false)
        #expect(writer.hasBufferCapacity(1024))

        var buffered = 0
        while true {
            let result = writer.write(ETPacket(encrypted: false, header: UInt8(buffered % 256), payload: chunk))
            if result == .skipped { break }
            guard result == .bufferedOnly else {
                Issue.record("expected .bufferedOnly while disconnected, got \(result)")
                return
            }
            buffered += 1
            #expect(buffered <= Int(ETBackedWriter.disconnectBufferBytes / (1024 * 1024)))
        }
        #expect(buffered >= Int(ETBackedWriter.disconnectBufferBytes / (1024 * 1024)) - 1)
        #expect(!writer.hasBufferCapacity(2 * 1024 * 1024))

        writer.revive(connected: true)
        #expect(writer.hasBufferCapacity(1024))
        writer.revive(connected: false)
        #expect(writer.write(ETPacket(encrypted: false, header: 1, payload: chunk)) == .bufferedOnly)
    }

    @Test("The backup buffer trims to 64MB while connected, and recover() rejects a range extending past what's retained")
    func trimsOldDataAndRejectsTooFarBehind() throws {
        let writer = ETBackedWriter(cryptoStream: ETCryptoStream(key: Self.key, directionByte: 0), connected: true)
        let chunk = [UInt8](repeating: 0x78, count: 1024 * 1024) // 1MB

        // 70MB of writes while connected exceeds the 64MB backup cap.
        for i in 0..<70 {
            guard case .ready = writer.write(ETPacket(encrypted: false, header: UInt8(i % 256), payload: chunk)) else {
                Issue.record("expected .ready while connected")
                return
            }
        }
        #expect(writer.sequenceNumber == 70)

        writer.revive(connected: false)

        #expect(throws: ETBackedWriter.RecoverError.tooFarBehind) {
            try writer.recover(lastValidSequenceNumber: 0)
        }

        let recovered = try writer.recover(lastValidSequenceNumber: writer.sequenceNumber - 10)
        #expect(recovered.count == 10)
    }

    @Test("recover() rejects a peer claiming to be ahead of what was actually sent")
    func rejectsPeerAheadOfSelf() throws {
        let writer = ETBackedWriter(cryptoStream: ETCryptoStream(key: Self.key, directionByte: 0), connected: true)
        _ = writer.write(ETPacket(encrypted: false, header: 1, payload: [1]))
        writer.revive(connected: false)
        #expect(throws: ETBackedWriter.RecoverError.peerAheadOfSelf) {
            try writer.recover(lastValidSequenceNumber: 5)
        }
    }

    @Test("recover() refuses to run while still connected")
    func rejectsRecoverWhileConnected() {
        let writer = ETBackedWriter(cryptoStream: ETCryptoStream(key: Self.key, directionByte: 0), connected: true)
        #expect(throws: ETBackedWriter.RecoverError.stillConnected) {
            try writer.recover(lastValidSequenceNumber: 0)
        }
    }

    @Test("recover() with nothing new to recover returns an empty array without touching the buffer")
    func recoverWithNothingNewReturnsEmpty() throws {
        let writer = ETBackedWriter(cryptoStream: ETCryptoStream(key: Self.key, directionByte: 0), connected: true)
        _ = writer.write(ETPacket(encrypted: false, header: 1, payload: [1]))
        writer.revive(connected: false)
        let recovered = try writer.recover(lastValidSequenceNumber: writer.sequenceNumber)
        #expect(recovered.isEmpty)
    }
}
