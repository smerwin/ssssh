import Foundation

/// Mirrors `TransportBuffers.Instruction` (`src/protobufs/transportinstruction.proto`):
/// the transport-layer envelope carrying a state-sync diff in each direction.
struct MoshTransportInstruction {
    /// The only value mosh's wire protocol accepts (`MOSH_PROTOCOL_VERSION`
    /// in `network.h`, "bumped for echo-ack").
    static let expectedProtocolVersion: UInt64 = 2

    var protocolVersion: UInt64 = MoshTransportInstruction.expectedProtocolVersion
    var oldNum: UInt64 = 0
    var newNum: UInt64 = 0
    var ackNum: UInt64 = 0
    var throwawayNum: UInt64 = 0
    var diff: [UInt8] = []
    var chaff: [UInt8] = []

    func serialize() -> [UInt8] {
        var w = MoshProtobuf.Writer()
        w.writeVarint(field: 1, value: protocolVersion)
        w.writeVarint(field: 2, value: oldNum)
        w.writeVarint(field: 3, value: newNum)
        w.writeVarint(field: 4, value: ackNum)
        w.writeVarint(field: 5, value: throwawayNum)
        w.writeBytes(field: 6, value: diff)
        w.writeBytes(field: 7, value: chaff)
        return w.bytes
    }

    static func parse(_ data: [UInt8]) throws -> MoshTransportInstruction {
        var result = MoshTransportInstruction()
        for field in try MoshProtobuf.parseFields(data) {
            switch field.number {
            case 1: result.protocolVersion = field.varint ?? 0
            case 2: result.oldNum = field.varint ?? 0
            case 3: result.newNum = field.varint ?? 0
            case 4: result.ackNum = field.varint ?? 0
            case 5: result.throwawayNum = field.varint ?? 0
            case 6: result.diff = field.bytes ?? []
            case 7: result.chaff = field.bytes ?? []
            default: break // a future field we don't need
            }
        }
        return result
    }
}

/// Mirrors `ClientBuffers.UserMessage`/`Instruction`/`Keystroke`/`ResizeMessage`
/// (`src/protobufs/userinput.proto`) -- what the client sends the server as
/// the `diff` payload of an outgoing `MoshTransportInstruction`. Proto2
/// extension fields (`keystroke` = field 2, `resize` = field 3 on the
/// shared `Instruction` extension range) are ordinary length-delimited
/// fields on the wire; there is no different wire representation to
/// account for, only a source-level naming convention on the C++ side.
enum MoshUserInstruction {
    case keystroke([UInt8])
    case resize(width: Int, height: Int)

    /// Serializes this as one `ClientBuffers.Instruction` sub-message (the
    /// proto2 extension wrapper) -- not yet wrapped in `UserMessage`'s
    /// `repeated Instruction instruction = 1`, which `MoshUserMessage`
    /// handles by nesting this as a length-delimited field 1.
    fileprivate func serializeInstruction() -> [UInt8] {
        var inst = MoshProtobuf.Writer()
        switch self {
        case .keystroke(let bytes):
            var inner = MoshProtobuf.Writer()
            inner.writeBytes(field: 4, value: bytes, omitIfEmpty: false)
            inst.writeBytes(field: 2, value: inner.bytes, omitIfEmpty: false)
        case .resize(let width, let height):
            var inner = MoshProtobuf.Writer()
            inner.writeVarint(field: 5, value: UInt64(bitPattern: Int64(width)))
            inner.writeVarint(field: 6, value: UInt64(bitPattern: Int64(height)))
            inst.writeBytes(field: 3, value: inner.bytes, omitIfEmpty: false)
        }
        return inst.bytes
    }
}

struct MoshUserMessage {
    var instructions: [MoshUserInstruction] = []

    func serialize() -> [UInt8] {
        var w = MoshProtobuf.Writer()
        for instruction in instructions {
            w.writeBytes(field: 1, value: instruction.serializeInstruction(), omitIfEmpty: false)
        }
        return w.bytes
    }
}

/// Mirrors `HostBuffers.HostMessage`/`Instruction`/`HostBytes`/`ResizeMessage`/`EchoAck`
/// (`src/protobufs/hostinput.proto`) -- what arrives from the server as the
/// `diff` payload of an incoming `MoshTransportInstruction`.
enum MoshHostInstruction {
    case hostBytes([UInt8])
    case resize(width: Int, height: Int)
    case echoAck(UInt64)

    static func parse(_ data: [UInt8]) throws -> MoshHostInstruction? {
        for field in try MoshProtobuf.parseFields(data) {
            switch field.number {
            case 2: // hostbytes
                guard let inner = field.bytes else { continue }
                var bytes: [UInt8] = []
                for innerField in try MoshProtobuf.parseFields(inner) where innerField.number == 4 {
                    bytes = innerField.bytes ?? []
                }
                return .hostBytes(bytes)
            case 3: // resize
                guard let inner = field.bytes else { continue }
                var width = 0
                var height = 0
                for innerField in try MoshProtobuf.parseFields(inner) {
                    if innerField.number == 5 { width = Int(Int64(bitPattern: innerField.varint ?? 0)) }
                    if innerField.number == 6 { height = Int(Int64(bitPattern: innerField.varint ?? 0)) }
                }
                return .resize(width: width, height: height)
            case 7: // echoack
                guard let inner = field.bytes else { continue }
                var echoAckNum: UInt64 = 0
                for innerField in try MoshProtobuf.parseFields(inner) where innerField.number == 8 {
                    echoAckNum = innerField.varint ?? 0
                }
                return .echoAck(echoAckNum)
            default:
                continue // an Instruction extension we don't know about
            }
        }
        return nil
    }
}

struct MoshHostMessage {
    var instructions: [MoshHostInstruction] = []

    static func parse(_ data: [UInt8]) throws -> MoshHostMessage {
        var result = MoshHostMessage()
        for field in try MoshProtobuf.parseFields(data) where field.number == 1 {
            guard let bytes = field.bytes, let instruction = try MoshHostInstruction.parse(bytes) else { continue }
            result.instructions.append(instruction)
        }
        return result
    }
}
