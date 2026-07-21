import Foundation

/// Mirrors `Packet` (`src/base/Packet.hpp`): the wire envelope around
/// every message ET sends, independent of whatever protobuf payload it
/// carries. `encrypted` and `header` are never covered by encryption or
/// the MAC -- only `payload` is (`ETCryptoStream`/`ETSecretBox` operate on
/// `payload` alone; a caller wraps/unwraps this envelope around that).
struct ETPacket: Equatable {
    var encrypted: Bool
    var header: UInt8
    var payload: [UInt8]

    /// `encrypted(1) || header(1) || payload` -- matches `Packet::serialize`.
    func serialize() -> [UInt8] {
        [encrypted ? 1 : 0, header] + payload
    }

    enum ParseError: Error, Equatable { case tooShort }

    /// Matches `Packet(const string& serializedPacket)`, which reads
    /// `serializedPacket[0]`/`[1]` unconditionally -- a serialized packet
    /// shorter than 2 bytes is not something the real client ever
    /// produces, but a hostile or corrupt peer could send one, so this
    /// rejects it explicitly rather than trapping on an out-of-bounds
    /// access the way an unchecked port of the C++ would.
    static func parse(_ bytes: [UInt8]) throws -> ETPacket {
        guard bytes.count >= 2 else { throw ParseError.tooShort }
        return ETPacket(encrypted: bytes[0] != 0, header: bytes[1], payload: Array(bytes[2...]))
    }
}

/// Incrementally reassembles `ETPacket`s from a raw byte stream carrying
/// ET's length-prefixed wire framing. Feed it arbitrarily-chunked bytes as
/// they arrive off a TCP connection (`NWConnection` delivers data in
/// whatever chunks the kernel hands back, not aligned to message
/// boundaries); it returns every packet that becomes complete as a result.
///
/// **The length prefix is 8 bytes, little-endian** -- confirmed by reading
/// `SocketHandler::readPacket`/`writePacket` (`src/base/SocketHandler.hpp`)
/// directly: they `readAll`/`writeAllOrThrow` a raw `int64_t` with no
/// byte-swap anywhere in that path, which is little-endian in practice
/// since every platform ET ships for is. This corrects an earlier, wrong
/// "4-byte big-endian" assumption in CLAUDE.md's Eternal Terminal notes --
/// see the correction there for detail. Get this wrong and every message
/// past the first desyncs silently, not just the current one.
final class ETPacketStreamReader {
    /// Matches `SocketHandler`'s own bound (128 MB) -- also doubles as
    /// protection against a corrupt or hostile length prefix driving
    /// unbounded buffer growth while waiting for the rest of a "packet"
    /// that will never arrive.
    static let maxPacketLength: Int64 = 128 * 1024 * 1024

    private var buffer: [UInt8] = []

    enum StreamError: Error, Equatable { case invalidLength(Int64) }

    /// Appends newly-received bytes and returns every `ETPacket` that
    /// became complete as a result (zero, one, or several, depending on
    /// how the underlying reads happened to chunk). A zero-length message
    /// (`length == 0`) is consumed from the stream but produces no
    /// `ETPacket` -- matching `readPacket` returning `false` rather than
    /// trying to parse an empty payload as a real packet.
    func feed(_ bytes: [UInt8]) throws -> [ETPacket] {
        buffer.append(contentsOf: bytes)
        var packets: [ETPacket] = []
        while buffer.count >= 8 {
            let length = Self.readLengthPrefix(buffer)
            guard length >= 0 && length <= Self.maxPacketLength else {
                throw StreamError.invalidLength(length)
            }
            let total = 8 + Int(length)
            guard buffer.count >= total else { break }
            if length > 0 {
                let packetBytes = Array(buffer[8..<total])
                packets.append(try ETPacket.parse(packetBytes))
            }
            buffer.removeFirst(total)
        }
        return packets
    }

    private static func readLengthPrefix(_ buffer: [UInt8]) -> Int64 {
        var value: UInt64 = 0
        for i in 0..<8 {
            value |= UInt64(buffer[i]) << (8 * i)
        }
        return Int64(bitPattern: value)
    }

    /// Prepends the 8-byte little-endian length prefix around a serialized
    /// packet -- the sender-side counterpart to `feed`, matching
    /// `writePacket`.
    static func frame(_ packet: ETPacket) -> [UInt8] {
        let serialized = packet.serialize()
        let length = UInt64(serialized.count)
        var out = [UInt8](repeating: 0, count: 8)
        for i in 0..<8 {
            out[i] = UInt8((length >> (8 * i)) & 0xff)
        }
        out.append(contentsOf: serialized)
        return out
    }
}
