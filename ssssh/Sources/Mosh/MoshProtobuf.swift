import Foundation

/// A minimal hand-rolled protobuf (proto2, wire format only) reader/writer
/// for the handful of small messages mosh's transport layer uses
/// (`TransportBuffers.Instruction`, `ClientBuffers.UserMessage`,
/// `HostBuffers.HostMessage`, defined in mosh's own
/// `src/protobufs/*.proto`). Pulling in a full protobuf runtime for three
/// tiny fixed-shape messages (a handful of varint/uint64 fields plus one
/// bytes field each) would be a much bigger dependency than the problem
/// warrants; this implements just enough of the wire format
/// (https://protobuf.dev/programming-guides/encoding/) to round-trip them.
///
/// Only varint (wire type 0) and length-delimited (wire type 2) fields are
/// needed -- none of mosh's messages use fixed32/fixed64/embedded messages
/// at the top level (the "extension" fields in `ClientBuffers`/
/// `HostBuffers` are encoded as ordinary length-delimited fields on the
/// wire; proto2 extensions are a source-level concept, not a different
/// wire representation).
enum MoshProtobuf {
    struct DecodeError: Error {}

    struct Writer {
        private(set) var bytes: [UInt8] = []

        /// Omits the field entirely when `value == 0`. This diverges from
        /// what protoc's generated C++ would emit if a field was
        /// explicitly `set_foo(0)` (it still writes a present-but-zero
        /// field in that case) -- but every reader here, including mosh's
        /// own (`networktransport-impl.h`'s `recv()`), only ever calls the
        /// plain accessor (`inst.old_num()`, never `inst.has_old_num()`),
        /// and proto2 scalar accessors return the same default (0) whether
        /// a field was omitted or explicitly zero. The two encodings are
        /// therefore indistinguishable to every consumer that matters here.
        mutating func writeVarint(field: Int, value: UInt64) {
            guard value != 0 else { return }
            writeTag(field: field, wireType: 0)
            writeRawVarint(value)
        }

        /// Same reasoning as `writeVarint` for the default (omit when
        /// empty): every reader here treats an absent bytes field and a
        /// present-but-empty one identically (`.diff().empty()`, never
        /// `.has_diff()`). `omitIfEmpty: false` exists only in case a
        /// future caller needs a byte-identical encoding for some other
        /// reason.
        mutating func writeBytes(field: Int, value: [UInt8], omitIfEmpty: Bool = true) {
            guard !(omitIfEmpty && value.isEmpty) else { return }
            writeTag(field: field, wireType: 2)
            writeRawVarint(UInt64(value.count))
            bytes.append(contentsOf: value)
        }

        private mutating func writeTag(field: Int, wireType: UInt8) {
            writeRawVarint((UInt64(field) << 3) | UInt64(wireType))
        }

        private mutating func writeRawVarint(_ value: UInt64) {
            var v = value
            while true {
                let byte = UInt8(v & 0x7F)
                v >>= 7
                if v != 0 {
                    bytes.append(byte | 0x80)
                } else {
                    bytes.append(byte)
                    break
                }
            }
        }
    }

    struct Field {
        let number: Int
        let varint: UInt64?
        let bytes: [UInt8]?
    }

    static func parseFields(_ data: [UInt8]) throws -> [Field] {
        var fields: [Field] = []
        var i = 0
        while i < data.count {
            let (tag, tagLen) = try readVarint(data, at: i)
            i += tagLen
            let fieldNumber = Int(tag >> 3)
            let wireType = tag & 0x7

            switch wireType {
            case 0:
                let (value, len) = try readVarint(data, at: i)
                i += len
                fields.append(Field(number: fieldNumber, varint: value, bytes: nil))
            case 2:
                let (length, lenBytes) = try readVarint(data, at: i)
                i += lenBytes
                // `length` is an attacker-controlled varint (up to
                // UInt64.max) straight out of the server's decrypted
                // payload. Comparing it against the remaining byte count
                // before ever converting it to `Int` avoids `Int(length)`
                // trapping on a value above `Int.max` -- a single crafted
                // length field would otherwise crash the client, no need
                // to defeat OCB authentication first since the legitimate
                // key-holder can already craft this plaintext.
                let remaining = data.count - i
                guard length <= UInt64(remaining) else { throw DecodeError() }
                let len = Int(length)
                fields.append(Field(number: fieldNumber, varint: nil, bytes: Array(data[i..<(i + len)])))
                i += len
            case 1:
                guard i + 8 <= data.count else { throw DecodeError() }
                i += 8
            case 5:
                guard i + 4 <= data.count else { throw DecodeError() }
                i += 4
            default:
                throw DecodeError()
            }
        }
        return fields
    }

    private static func readVarint(_ data: [UInt8], at start: Int) throws -> (UInt64, Int) {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var i = start
        while true {
            guard i < data.count else { throw DecodeError() }
            let byte = data[i]
            result |= UInt64(byte & 0x7F) << shift
            i += 1
            if byte & 0x80 == 0 { break }
            shift += 7
            guard shift < 64 else { throw DecodeError() }
        }
        return (result, i - start)
    }
}
