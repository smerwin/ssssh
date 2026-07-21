import Foundation
import Testing
@testable import ssssh

struct ETPacketTests {
    @Test("Serializes and parses a plain packet")
    func serializesAndParses() throws {
        let packet = ETPacket(encrypted: false, header: 42, payload: [1, 2, 3, 4])
        let bytes = packet.serialize()
        #expect(bytes == [0, 42, 1, 2, 3, 4])
        #expect(try ETPacket.parse(bytes) == packet)
    }

    @Test("Round-trips an encrypted packet with an empty payload")
    func roundTripsEmptyEncryptedPayload() throws {
        let packet = ETPacket(encrypted: true, header: 254, payload: [])
        let bytes = packet.serialize()
        #expect(bytes == [1, 254])
        #expect(try ETPacket.parse(bytes) == packet)
    }

    @Test("Rejects a serialized packet shorter than the 2-byte header")
    func rejectsTooShort() {
        #expect(throws: ETPacket.ParseError.tooShort) {
            try ETPacket.parse([1])
        }
        #expect(throws: ETPacket.ParseError.tooShort) {
            try ETPacket.parse([])
        }
    }

    @Test("frame() prepends an 8-byte little-endian length prefix")
    func framePrependsLittleEndianLength() {
        let packet = ETPacket(encrypted: false, header: 1, payload: Array(repeating: 0xAB, count: 300))
        let framed = ETPacketStreamReader.frame(packet)
        // serialized length = 2 (header) + 300 (payload) = 302 = 0x12E
        #expect(Array(framed[0..<8]) == [0x2E, 0x01, 0, 0, 0, 0, 0, 0])
        #expect(framed.count == 8 + 302)
    }

    @Test("Reader round-trips a single packet fed in one call")
    func readsSinglePacketWholeFeed() throws {
        let packet = ETPacket(encrypted: true, header: 1, payload: [9, 9, 9])
        let framed = ETPacketStreamReader.frame(packet)
        let reader = ETPacketStreamReader()
        let result = try reader.feed(framed)
        #expect(result == [packet])
    }

    @Test("Reader reassembles a packet fed as arbitrary, unaligned byte chunks")
    func readsPacketAcrossArbitraryChunkBoundaries() throws {
        let packet = ETPacket(encrypted: false, header: 5, payload: Array((0..<200).map { UInt8($0 % 256) }))
        let framed = ETPacketStreamReader.frame(packet)
        let reader = ETPacketStreamReader()

        // Feed in irregular 3-byte chunks, deliberately not aligned to the
        // 8-byte length prefix or any other structure -- this is the
        // realistic case for TCP, which has no message-boundary concept.
        var collected: [ETPacket] = []
        var offset = 0
        while offset < framed.count {
            let end = min(offset + 3, framed.count)
            collected.append(contentsOf: try reader.feed(Array(framed[offset..<end])))
            offset = end
        }
        #expect(collected == [packet])
    }

    @Test("Reader returns multiple packets delivered in a single feed call")
    func readsMultiplePacketsInOneFeed() throws {
        let first = ETPacket(encrypted: false, header: 1, payload: [1])
        let second = ETPacket(encrypted: true, header: 2, payload: [2, 2])
        let combined = ETPacketStreamReader.frame(first) + ETPacketStreamReader.frame(second)
        let reader = ETPacketStreamReader()
        let result = try reader.feed(combined)
        #expect(result == [first, second])
    }

    @Test("Reader consumes a zero-length message without emitting a packet")
    func consumesZeroLengthMessage() throws {
        let reader = ETPacketStreamReader()
        let zeroLengthPrefix: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0]
        let real = ETPacket(encrypted: false, header: 3, payload: [7])
        let combined = zeroLengthPrefix + ETPacketStreamReader.frame(real)
        let result = try reader.feed(combined)
        #expect(result == [real])
    }

    @Test("Reader throws on a length prefix beyond the 128 MB bound")
    func rejectsOversizedLength() {
        let reader = ETPacketStreamReader()
        // 129 * 1024 * 1024, little-endian, as an 8-byte prefix with no
        // payload following -- the reader must reject based on the length
        // field alone, before waiting for (or receiving) that much data.
        let hugeLength: Int64 = 129 * 1024 * 1024
        var prefix = [UInt8](repeating: 0, count: 8)
        for i in 0..<8 {
            prefix[i] = UInt8((UInt64(bitPattern: hugeLength) >> (8 * i)) & 0xff)
        }
        #expect(throws: ETPacketStreamReader.StreamError.self) {
            try reader.feed(prefix)
        }
    }

    @Test("Reader throws on a negative length prefix")
    func rejectsNegativeLength() {
        let reader = ETPacketStreamReader()
        let negativeOne: [UInt8] = Array(repeating: 0xff, count: 8)
        #expect(throws: ETPacketStreamReader.StreamError.self) {
            try reader.feed(negativeOne)
        }
    }
}
