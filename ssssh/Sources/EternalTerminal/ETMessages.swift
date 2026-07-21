import Foundation

/// The one-byte dispatch space `Packet.header` (`src/base/Packet.hpp`)
/// actually lives in: `EtPacketType` (`proto/ET.proto`) and
/// `TerminalPacketType` (`proto/ETerminal.proto`) are two separate proto
/// enums, but `EtPacketType`'s values are deliberately numbered 252-254
/// ("count down from 254 to avoid collisions", per its own source comment)
/// while `TerminalPacketType`'s run 0-10 -- non-overlapping by
/// construction, so both share `Packet`'s single header byte unambiguously.
/// This app doesn't yet send anything needing `PORT_FORWARD_*`/
/// `JUMPHOST_INIT` (see CLAUDE.md's "out of scope for a first pass" note),
/// but the cases are listed for completeness/future use.
enum ETPacketHeader: UInt8 {
    case keepAlive = 0
    case terminalBuffer = 1
    case terminalInfo = 2
    case portForwardDestinationRequest = 5
    case portForwardDestinationResponse = 6
    case portForwardData = 7
    case terminalUserInfo = 8
    case terminalInit = 9
    case jumphostInit = 10
    case initialResponse = 252
    case initialPayload = 253
    case heartbeat = 254
}

/// `message ConnectRequest` (`proto/ET.proto`).
struct ETConnectRequest {
    var clientId: String = ""
    var version: Int32 = 0

    func encode() -> [UInt8] {
        var w = ETProtobuf.Writer()
        w.writeString(field: 1, value: clientId)
        w.writeSignedVarint(field: 2, value: Int64(version))
        return w.bytes
    }

    static func decode(_ data: [UInt8]) throws -> ETConnectRequest {
        var result = ETConnectRequest()
        for field in try ETProtobuf.parseFields(data) {
            switch field.number {
            case 1: result.clientId = field.string ?? ""
            case 2: result.version = Int32(truncatingIfNeeded: field.signedVarint ?? 0)
            default: break
            }
        }
        return result
    }
}

/// `enum ConnectStatus` (`proto/ET.proto`).
enum ETConnectStatus: Int64 {
    case newClient = 1
    case returningClient = 2
    case invalidKey = 3
    case mismatchedProtocol = 4
}

/// `message ConnectResponse` (`proto/ET.proto`).
struct ETConnectResponse {
    var status: ETConnectStatus?
    var error: String = ""

    func encode() -> [UInt8] {
        var w = ETProtobuf.Writer()
        if let status { w.writeVarint(field: 1, value: UInt64(status.rawValue)) }
        w.writeString(field: 2, value: error)
        return w.bytes
    }

    static func decode(_ data: [UInt8]) throws -> ETConnectResponse {
        var result = ETConnectResponse()
        for field in try ETProtobuf.parseFields(data) {
            switch field.number {
            case 1: result.status = field.varint.flatMap { ETConnectStatus(rawValue: Int64($0)) }
            case 2: result.error = field.string ?? ""
            default: break
            }
        }
        return result
    }
}

/// `message TerminalBuffer` (`proto/ETerminal.proto`) -- raw PTY output
/// bytes, unlike Mosh's `HostBytes` this is a literal byte passthrough
/// with no framebuffer-diff modeling (see CLAUDE.md's "Why native
/// scrolling and tmux -CC work" note).
struct ETTerminalBuffer {
    var buffer: [UInt8] = []

    func encode() -> [UInt8] {
        var w = ETProtobuf.Writer()
        w.writeBytes(field: 1, value: buffer)
        return w.bytes
    }

    static func decode(_ data: [UInt8]) throws -> ETTerminalBuffer {
        var result = ETTerminalBuffer()
        for field in try ETProtobuf.parseFields(data) {
            if field.number == 1 { result.buffer = field.bytes ?? [] }
        }
        return result
    }
}

/// `message TerminalInfo` (`proto/ETerminal.proto`) -- PTY resize.
struct ETTerminalInfo {
    var id: String = ""
    var row: Int32 = 0
    var column: Int32 = 0
    var width: Int32 = 0
    var height: Int32 = 0

    func encode() -> [UInt8] {
        var w = ETProtobuf.Writer()
        w.writeString(field: 1, value: id)
        w.writeSignedVarint(field: 2, value: Int64(row))
        w.writeSignedVarint(field: 3, value: Int64(column))
        w.writeSignedVarint(field: 4, value: Int64(width))
        w.writeSignedVarint(field: 5, value: Int64(height))
        return w.bytes
    }

    static func decode(_ data: [UInt8]) throws -> ETTerminalInfo {
        var result = ETTerminalInfo()
        for field in try ETProtobuf.parseFields(data) {
            switch field.number {
            case 1: result.id = field.string ?? ""
            case 2: result.row = Int32(truncatingIfNeeded: field.signedVarint ?? 0)
            case 3: result.column = Int32(truncatingIfNeeded: field.signedVarint ?? 0)
            case 4: result.width = Int32(truncatingIfNeeded: field.signedVarint ?? 0)
            case 5: result.height = Int32(truncatingIfNeeded: field.signedVarint ?? 0)
            default: break
            }
        }
        return result
    }
}

/// `message TermInit` (`proto/ETerminal.proto`) -- two parallel repeated
/// string lists (name/value pairs by matching index), *not* a `map` field
/// despite carrying environment variables the same way `InitialPayload`'s
/// actual `map<string, string>` field does; this one needs no map support.
struct ETTermInit {
    var environmentNames: [String] = []
    var environmentValues: [String] = []

    func encode() -> [UInt8] {
        var w = ETProtobuf.Writer()
        for name in environmentNames { w.writeString(field: 1, value: name, omitIfEmpty: false) }
        for value in environmentValues { w.writeString(field: 2, value: value, omitIfEmpty: false) }
        return w.bytes
    }

    static func decode(_ data: [UInt8]) throws -> ETTermInit {
        var result = ETTermInit()
        for field in try ETProtobuf.parseFields(data) {
            switch field.number {
            case 1: result.environmentNames.append(field.string ?? "")
            case 2: result.environmentValues.append(field.string ?? "")
            default: break
            }
        }
        return result
    }
}

/// `message TerminalUserInfo` (`proto/ETerminal.proto`) -- carries the
/// bootstrap id/passkey (`ETBootstrap.Result`) into the terminal-level
/// session once the TCP connection is established.
struct ETTerminalUserInfo {
    var id: String = ""
    var passkey: String = ""
    var uid: Int64 = 0
    var gid: Int64 = 0
    var fd: Int64 = 0

    func encode() -> [UInt8] {
        var w = ETProtobuf.Writer()
        w.writeString(field: 1, value: id)
        w.writeString(field: 2, value: passkey)
        w.writeSignedVarint(field: 3, value: uid)
        w.writeSignedVarint(field: 4, value: gid)
        w.writeSignedVarint(field: 5, value: fd)
        return w.bytes
    }

    static func decode(_ data: [UInt8]) throws -> ETTerminalUserInfo {
        var result = ETTerminalUserInfo()
        for field in try ETProtobuf.parseFields(data) {
            switch field.number {
            case 1: result.id = field.string ?? ""
            case 2: result.passkey = field.string ?? ""
            case 3: result.uid = field.signedVarint ?? 0
            case 4: result.gid = field.signedVarint ?? 0
            case 5: result.fd = field.signedVarint ?? 0
            default: break
            }
        }
        return result
    }
}
