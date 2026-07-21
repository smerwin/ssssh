import Foundation

/// A minimal hand-rolled protobuf (proto2, wire format only) reader/writer
/// for ET's own small messages (`proto/ET.proto`/`proto/ETerminal.proto`).
/// Deliberately not shared with `MoshProtobuf` despite near-identical wire
/// mechanics -- the two protocol implementations are independent
/// subsystems in this codebase (see CLAUDE.md's Mosh and Eternal Terminal
/// sections, each self-contained), and coupling them would make a change
/// motivated by one protocol's needs a risk to the other's.
///
/// Covers varint (wire type 0) and length-delimited (wire type 2) fields --
/// every message this app actually needs for a first-pass terminal session
/// (`ConnectRequest`, `ConnectResponse`, `TerminalUserInfo`, `TermInit`,
/// `TerminalBuffer`, `TerminalInfo`) uses only `optional`/`repeated`
/// string, bytes, int32, and int64 fields, none of which need fixed32/
/// fixed64 or embedded messages. `InitialPayload` is the one message in
/// ET's schema needing `map<string, string>` support (for jumphost/
/// port-forward environment variable forwarding) -- deliberately not
/// implemented here since jumphost/port-forwarding is out of this pass's
/// scope (see CLAUDE.md's "Port-forwarding / jumphost" note); add map
/// support (a `map<K, V>` field is just a repeated two-field submessage on
/// the wire, `{key = 1; value = 2;}`) if that scope ever changes.
enum ETProtobuf {
    struct DecodeError: Error {}

    struct Writer {
        private(set) var bytes: [UInt8] = []

        /// Omits the field entirely when `value == 0`, matching every
        /// reader here calling the plain accessor rather than
        /// `has_foo()` -- an absent field and an explicit zero are
        /// indistinguishable to any consumer that matters.
        mutating func writeVarint(field: Int, value: UInt64) {
            guard value != 0 else { return }
            writeTag(field: field, wireType: 0)
            writeRawVarint(value)
        }

        /// proto2's plain `int32`/`int64` (not `sint32`/`sint64`) encode a
        /// negative value by sign-extending to 64 bits and varint-encoding
        /// that -- always the full 10-byte varint, per the protobuf wire
        /// format spec, not a shorter zigzag encoding. Delegates to the
        /// same `writeRawVarint` used for unsigned fields: right-shifting
        /// a `UInt64` bit-pattern of a negative `Int64` naturally produces
        /// exactly 10 groups of 7 bits before reaching zero.
        mutating func writeSignedVarint(field: Int, value: Int64) {
            guard value != 0 else { return }
            writeTag(field: field, wireType: 0)
            writeRawVarint(UInt64(bitPattern: value))
        }

        mutating func writeBytes(field: Int, value: [UInt8], omitIfEmpty: Bool = true) {
            guard !(omitIfEmpty && value.isEmpty) else { return }
            writeTag(field: field, wireType: 2)
            writeRawVarint(UInt64(value.count))
            bytes.append(contentsOf: value)
        }

        mutating func writeString(field: Int, value: String, omitIfEmpty: Bool = true) {
            writeBytes(field: field, value: Array(value.utf8), omitIfEmpty: omitIfEmpty)
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

        /// The raw varint reinterpreted as a signed 64-bit value -- for
        /// proto2 `int64`/`int32` fields, which are plain (non-zigzag)
        /// varints on the wire; a negative source value round-trips
        /// through the full 64-bit sign-extended bit pattern regardless of
        /// which of the two the field was declared as.
        var signedVarint: Int64? {
            varint.map { Int64(bitPattern: $0) }
        }

        var string: String? {
            bytes.flatMap { String(bytes: $0, encoding: .utf8) }
        }
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
                // payload -- compared against the remaining byte count
                // before converting to `Int` so a crafted length can't
                // trap `Int(length)` for a value above `Int.max`. Same
                // reasoning as `MoshProtobuf.parseFields`.
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
