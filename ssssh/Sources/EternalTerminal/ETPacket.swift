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
/// the framing `BackedReader`/`BackedWriter` (`src/base/BackedReader.cpp`'s
/// `getPartialMessageLength`/`constructPartialMessage`,
/// `src/base/BackedWriter.cpp`'s `write`) actually use on the live
/// connection for every ordinary packet (`TerminalBuffer`, `TerminalInfo`,
/// etc.) -- **not** `SocketHandler::readPacket`/`writePacket`'s 8-byte
/// mechanism (see `ETRecoveryProto` for where that one really is used).
///
/// **This is a correction of a correction.** An earlier pass through this
/// file read `SocketHandler::readPacket`/`writePacket`
/// (`src/base/SocketHandler.hpp`) and concluded the wire used an 8-byte
/// little-endian length prefix everywhere, fixing an original wrong
/// "4-byte big-endian" guess. That fix was itself incomplete: reading
/// `BackedReader.cpp`/`BackedWriter.cpp` directly (the classes `Connection`
/// -- the class actually driving the live client/server session, per
/// `src/base/Connection.hpp` -- owns and calls) shows they never call
/// `SocketHandler::readPacket`/`writePacket` at all. They implement their
/// *own* inline framing directly against the raw `SocketHandler::read`/
/// `write` primitives: `BackedWriter::write` does
/// `messageSize = htonl(packet.length()); string s = string("0000") +
/// packet.serialize(); memcpy(&s[0], &messageSize, sizeof(int));` --
/// a **4-byte**, **big-endian** (`htonl`) prefix, `sizeof(int)` not
/// `sizeof(int64_t)`. `BackedReader::getPartialMessageLength` decodes it
/// symmetrically with `ntohl`. The 8-byte int64 mechanism is real and
/// correctly described where it's actually used -- see `ETRecoveryProto`.
/// This is the second time a "confirmed by reading the source" claim in
/// this file turned out to be reading the *wrong* source for the question
/// being asked; if you're about to trust a framing/format claim here,
/// prefer finding the exact call site that produces the bytes on the wire
/// you care about over the first plausible-looking read/write helper.
final class ETPacketStreamReader {
    /// `BackedReader`/`BackedWriter` don't enforce an explicit size cap the
    /// way `SocketHandler::readPacket` does (128 MB) -- this reader still
    /// enforces one, as protection against a corrupt or hostile length
    /// prefix driving unbounded buffer growth while waiting for the rest of
    /// a "packet" that will never arrive. Arbitrary but generous relative
    /// to any real terminal-session message.
    static let maxPacketLength: Int32 = 128 * 1024 * 1024

    private var buffer: [UInt8] = []

    enum StreamError: Error, Equatable { case invalidLength(Int32) }

    /// Appends newly-received bytes and returns every `ETPacket` that
    /// became complete as a result (zero, one, or several, depending on
    /// how the underlying reads happened to chunk).
    func feed(_ bytes: [UInt8]) throws -> [ETPacket] {
        buffer.append(contentsOf: bytes)
        var packets: [ETPacket] = []
        while buffer.count >= 4 {
            let length = Self.readLengthPrefix(buffer)
            guard length >= 0 && length <= Self.maxPacketLength else {
                throw StreamError.invalidLength(length)
            }
            let total = 4 + Int(length)
            guard buffer.count >= total else { break }
            let packetBytes = Array(buffer[4..<total])
            packets.append(try ETPacket.parse(packetBytes))
            buffer.removeFirst(total)
        }
        return packets
    }

    private static func readLengthPrefix(_ buffer: [UInt8]) -> Int32 {
        let value = (UInt32(buffer[0]) << 24) | (UInt32(buffer[1]) << 16) | (UInt32(buffer[2]) << 8) | UInt32(buffer[3])
        return Int32(bitPattern: value)
    }

    /// Prepends the 4-byte big-endian (`htonl`) length prefix around a
    /// serialized packet -- the sender-side counterpart to `feed`, matching
    /// `BackedWriter::write`.
    static func frame(_ packet: ETPacket) -> [UInt8] {
        let serialized = packet.serialize()
        let length = UInt32(serialized.count)
        var out: [UInt8] = [
            UInt8((length >> 24) & 0xff),
            UInt8((length >> 16) & 0xff),
            UInt8((length >> 8) & 0xff),
            UInt8(length & 0xff),
        ]
        out.append(contentsOf: serialized)
        return out
    }
}

/// The 8-byte-int64-length-prefixed mechanism `SocketHandler::readProto`/
/// `writeProto` (`src/base/SocketHandler.hpp`) actually implement --
/// confirmed real, just not what governs the ordinary packet stream (see
/// `ETPacketStreamReader`'s doc comment). **Not recovery-specific despite
/// an earlier pass here naming this type `ETRecoveryProto`** -- reading
/// `ClientConnection::connect` (`src/base/ClientConnection.cpp`) shows the
/// *initial* handshake uses this exact same mechanism first: one
/// `ConnectRequest` written, one `ConnectResponse` read, on the brand-new
/// TCP socket, *before* any crypto state or `Packet` framing exists at
/// all. `Connection::recover` (`src/base/Connection.cpp`) reuses it later
/// for one `SequenceHeader` written, one read, then one `CatchupBuffer`
/// written, one read, on a freshly reconnected socket, before ordinary
/// `Packet` traffic resumes on it. Both are short, one-shot exchanges (not
/// a general streaming reassembler the way the packet stream needs) that
/// happen to use the identical wire mechanism -- one type correctly
/// serving both call sites, not a coincidence worth splitting apart. The
/// prefix is a raw `int64_t` memcpy with no byte-swap in that path, so
/// little-endian in practice (every platform ET ships for is).
enum ETOneShotProto {
    /// Matches `SocketHandler::readProto`/`writeProto`'s own bound.
    static let maxMessageLength: Int64 = 128 * 1024 * 1024

    enum OneShotProtoError: Error, Equatable { case invalidLength(Int64) }

    static func frame(_ bytes: [UInt8]) -> [UInt8] {
        let length = UInt64(bytes.count)
        var out = [UInt8](repeating: 0, count: 8)
        for i in 0..<8 {
            out[i] = UInt8((length >> (8 * i)) & 0xff)
        }
        out.append(contentsOf: bytes)
        return out
    }

    /// Parses exactly one length-prefixed message from the *start* of
    /// `buffer`, returning the payload and how many bytes were consumed,
    /// or `nil` if `buffer` doesn't yet contain a complete message.
    static func parseOne(_ buffer: [UInt8]) throws -> (payload: [UInt8], consumed: Int)? {
        guard buffer.count >= 8 else { return nil }
        var value: UInt64 = 0
        for i in 0..<8 { value |= UInt64(buffer[i]) << (8 * i) }
        let length = Int64(bitPattern: value)
        guard length >= 0 && length <= maxMessageLength else {
            throw OneShotProtoError.invalidLength(length)
        }
        let total = 8 + Int(length)
        guard buffer.count >= total else { return nil }
        return (Array(buffer[8..<total]), total)
    }
}
