import Foundation

/// Mirrors mosh's `Crypto::Session`/`Network::Packet` (`crypto.cc`,
/// `network.cc`): wraps `MoshOCB` with the exact nonce and framing
/// conventions mosh's wire protocol uses, so packets this produces are
/// byte-for-byte what a real `mosh-server` (or the reference mosh client)
/// would produce and accept.
///
/// Wire format for one UDP datagram, confirmed against mosh's source:
///   [8 bytes: big-endian (direction bit << 63 | 63-bit sequence)]
///   [OCB ciphertext of (2-byte big-endian timestamp
///                       || 2-byte big-endian timestamp-reply
///                       || payload), with a 16-byte tag appended]
/// The 12-byte nonce OCB actually uses is those same leading 8 bytes,
/// left-padded with 4 zero bytes -- not sent separately.
///
/// Caller-supplied `sequence` must never repeat for a given `direction`
/// under this session's key: nonce reuse breaks both privacy and
/// authenticity in OCB. Mosh guarantees this with a per-direction counter
/// that only ever increases for the life of a session.
final class MoshSession {
    enum Direction {
        case toServer
        case toClient

        fileprivate var bit: UInt64 {
            switch self {
            case .toServer: return 0
            case .toClient: return 1
            }
        }
    }

    struct Message {
        let direction: Direction
        let sequence: UInt64
        let timestamp: UInt16
        let timestampReply: UInt16
        let payload: [UInt8]
    }

    private static let directionMask: UInt64 = 1 << 63
    private static let sequenceMask: UInt64 = ~directionMask

    private let key: [UInt8]

    init(key: [UInt8]) {
        precondition(key.count == 16)
        self.key = key
    }

    func encrypt(direction: Direction, sequence: UInt64, timestamp: UInt16, timestampReply: UInt16, payload: [UInt8]) -> [UInt8] {
        let seqDirection = (direction.bit << 63) | (sequence & Self.sequenceMask)
        let wireNonce = Self.bigEndianBytes64(seqDirection)

        var plaintext = Self.bigEndianBytes16(timestamp)
        plaintext.append(contentsOf: Self.bigEndianBytes16(timestampReply))
        plaintext.append(contentsOf: payload)

        let ocbNonce: [UInt8] = [0, 0, 0, 0] + wireNonce
        let body = MoshOCB.encrypt(key: key, nonce: ocbNonce, plaintext: plaintext)
        return wireNonce + body
    }

    func decrypt(_ datagram: [UInt8]) throws -> Message {
        guard datagram.count >= 8 else { throw MoshOCB.AuthenticationFailure() }
        let wireNonce = Array(datagram.prefix(8))
        let body = Array(datagram.dropFirst(8))

        let seqDirection = Self.bigEndianValue64(wireNonce)
        let direction: Direction = (seqDirection & Self.directionMask) != 0 ? .toClient : .toServer
        let sequence = seqDirection & Self.sequenceMask

        let ocbNonce: [UInt8] = [0, 0, 0, 0] + wireNonce
        let plaintext = try MoshOCB.decrypt(key: key, nonce: ocbNonce, ciphertext: body)
        guard plaintext.count >= 4 else { throw MoshOCB.AuthenticationFailure() }

        let timestamp = Self.bigEndianValue16(Array(plaintext.prefix(2)))
        let timestampReply = Self.bigEndianValue16(Array(plaintext[2..<4]))
        let payload = Array(plaintext.dropFirst(4))
        return Message(direction: direction, sequence: sequence, timestamp: timestamp, timestampReply: timestampReply, payload: payload)
    }

    private static func bigEndianBytes64(_ value: UInt64) -> [UInt8] {
        (0..<8).map { UInt8(truncatingIfNeeded: value >> (56 - $0 * 8)) }
    }

    private static func bigEndianValue64(_ bytes: [UInt8]) -> UInt64 {
        bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    private static func bigEndianBytes16(_ value: UInt16) -> [UInt8] {
        [UInt8(value >> 8), UInt8(value & 0xFF)]
    }

    private static func bigEndianValue16(_ bytes: [UInt8]) -> UInt16 {
        (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
    }
}
