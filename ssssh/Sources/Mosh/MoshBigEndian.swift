import Foundation

/// Big-endian byte packing/unpacking shared by `MoshFragment` (fragment-set
/// id/number) and `MoshSession` (wire nonce, timestamp/timestamp-reply) --
/// pure, protocol-agnostic byte arithmetic with no framing- or
/// crypto-specific behavior of its own.
enum MoshBigEndian {
    static func bytes64(_ value: UInt64) -> [UInt8] {
        (0..<8).map { UInt8(truncatingIfNeeded: value >> (56 - $0 * 8)) }
    }

    static func value64(_ bytes: [UInt8]) -> UInt64 {
        bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    static func bytes16(_ value: UInt16) -> [UInt8] {
        [UInt8(value >> 8), UInt8(value & 0xFF)]
    }

    static func value16(_ bytes: [UInt8]) -> UInt16 {
        (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
    }
}
