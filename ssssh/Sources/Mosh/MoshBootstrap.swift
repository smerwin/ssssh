import Citadel
import Foundation
import NIOCore

/// Runs `mosh-server new` over an already-authenticated SSH connection and
/// parses its `MOSH CONNECT <port> <key>` reply -- the same handshake the
/// real `mosh` client performs before switching to its own UDP transport.
/// `mosh-server` (see `src/frontend/mosh-server.cc` upstream) prints that
/// line to stdout once its UDP socket is bound, then unconditionally forks:
/// the parent (the process our SSH exec channel is attached to) exits 0
/// immediately after, while the actual server keeps running detached. That
/// means this command always returns promptly, whether or not a mosh
/// session ever attaches to what it started.
///
/// This only detects mosh availability and retrieves the port/session key
/// for a freshly started `mosh-server`; it does not open the UDP connection
/// or hand the terminal's data path over to it. See CLAUDE.md's Mosh
/// section for what's still missing before that's possible.
enum MoshBootstrap {
    struct Result {
        let port: UInt16
        let sessionKey: [UInt8]
    }

    enum BootstrapError: LocalizedError {
        /// `mosh-server` isn't installed, isn't on PATH, needs a UTF-8
        /// locale it doesn't have, or otherwise didn't print a usable
        /// reply. `detail` is the command's raw combined output, useful in
        /// verbose-connecting diagnostics.
        case noMoshServer(detail: String)

        var errorDescription: String? {
            switch self {
            case .noMoshServer(let detail):
                let firstLine = detail.split(whereSeparator: \.isNewline).first.map(String.init) ?? "no output"
                return "mosh-server not available (\(firstLine))"
            }
        }
    }

    /// Runs `mosh-server new` on the given client and parses its reply.
    /// Throws `BootstrapError.noMoshServer` for anything that just means
    /// "no mosh upgrade available on this host" (not installed, command
    /// failed, unparsable output) -- callers should treat that as a normal,
    /// expected outcome on hosts without mosh, not a connection failure.
    static func detect(client: Citadel.SSHClient) async throws -> Result {
        let output: ByteBuffer
        do {
            output = try await client.executeCommand("mosh-server new -s", mergeStreams: true)
        } catch {
            throw BootstrapError.noMoshServer(detail: String(describing: error))
        }
        return try parse(output: String(buffer: output))
    }

    /// Parses `mosh-server`'s combined stdout+stderr for its
    /// `MOSH CONNECT <port> <key>` line, tolerating any surrounding
    /// banner/warning text (version banner, locale warnings, the detached-pid
    /// notice) that comes along on the same combined stream.
    static func parse(output: String) throws -> Result {
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ")
            guard fields.count == 4, fields[0] == "MOSH", fields[1] == "CONNECT" else { continue }
            guard let port = UInt16(fields[2]) else {
                throw BootstrapError.noMoshServer(detail: output)
            }
            guard let sessionKey = try? MoshSessionKey.parse(printableKey: String(fields[3])) else {
                throw BootstrapError.noMoshServer(detail: output)
            }
            return Result(port: port, sessionKey: sessionKey)
        }
        throw BootstrapError.noMoshServer(detail: output)
    }
}
