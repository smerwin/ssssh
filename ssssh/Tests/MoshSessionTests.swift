import Foundation
import Testing
@testable import ssssh

struct MoshSessionKeyTests {
    @Test("22-character printable key round-trips through parse/encode")
    func roundTrips() throws {
        for _ in 0..<20 {
            let bytes = MoshSessionKey.generateRandomForTesting()
            let printable = MoshSessionKey.printableKey(for: bytes)
            #expect(printable.count == 22)
            let parsed = try MoshSessionKey.parse(printableKey: printable)
            #expect(parsed == bytes)
        }
    }

    @Test("Rejects malformed printable keys")
    func rejectsMalformed() {
        #expect(throws: MoshSessionKey.InvalidKey.self) {
            try MoshSessionKey.parse(printableKey: "tooshort")
        }
        #expect(throws: MoshSessionKey.InvalidKey.self) {
            // 22 characters but not valid base64
            try MoshSessionKey.parse(printableKey: "!!!!!!!!!!!!!!!!!!!!!!")
        }
    }
}

struct MoshSessionTests {
    @Test("Round-trips a payload through encrypt/decrypt")
    func roundTrips() throws {
        let key = MoshSessionKey.generateRandomForTesting()
        let session = MoshSession(key: key)

        let datagram = session.encrypt(
            direction: .toServer,
            sequence: 5,
            timestamp: 1234,
            timestampReply: 5678,
            payload: Array("hello mosh".utf8)
        )

        let message = try session.decrypt(datagram)
        #expect(message.direction == .toServer)
        #expect(message.sequence == 5)
        #expect(message.timestamp == 1234)
        #expect(message.timestampReply == 5678)
        #expect(message.payload == Array("hello mosh".utf8))
    }

    @Test("Wire nonce packs direction into the top bit, big-endian sequence in the rest")
    func wireNonceLayout() {
        let key = MoshSessionKey.generateRandomForTesting()
        let session = MoshSession(key: key)

        let datagram = session.encrypt(direction: .toClient, sequence: 5, timestamp: 0, timestampReply: 0, payload: [])
        let wireNonce = Array(datagram.prefix(8))
        #expect(wireNonce == [0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x05])
    }

    @Test("Direction is part of decryption's associated context: swapping it fails authentication")
    func directionIsAuthenticated() {
        let key = MoshSessionKey.generateRandomForTesting()
        let session = MoshSession(key: key)

        var datagram = session.encrypt(direction: .toServer, sequence: 0, timestamp: 0, timestampReply: 0, payload: [1, 2, 3])
        // Flip the direction bit in the wire nonce -- since the nonce itself
        // feeds the OCB tag computation, this must invalidate the packet,
        // not just relabel it.
        datagram[0] ^= 0x80
        #expect(throws: MoshOCB.AuthenticationFailure.self) {
            try session.decrypt(datagram)
        }
    }
}
