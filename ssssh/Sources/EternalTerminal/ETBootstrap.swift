import Citadel
import Foundation
import Network
import NIOCore

/// Bootstraps an Eternal Terminal (ET) session: a bare TCP ping to confirm
/// `etserver` is actually listening, then a run of `etterminal` over an
/// already-authenticated SSH connection to register a freshly generated
/// id/passkey with it. This mirrors the real `et` client's own two-step
/// handshake exactly -- confirmed by reading `MisterTea/EternalTerminal`'s
/// own source (`src/terminal/TerminalClientMain.cpp`'s `ping`,
/// `src/terminal/SshSetupHandler.cpp`'s `SetupSsh`), not guessed. See
/// CLAUDE.md's "Eternal Terminal support" section for the wider protocol
/// research this is grounded in, including why this app only ever targets
/// hosts that already run `etserver` as a persistent service (this type
/// never starts one).
///
/// This only detects ET availability and registers a session id/passkey
/// with an already-running `etserver`; it does not open the ET-protocol TCP
/// connection or hand the terminal's data path over to it. That's
/// deliberately out of scope for this first pass -- see CLAUDE.md for what
/// wire-protocol work (XSalsa20-Poly1305 framing, the sequence-numbered
/// resend buffer, protobuf messages) is still needed before a live ET
/// session is possible.
enum ETBootstrap {
    struct Result: Equatable {
        let id: String
        let passkey: String
    }

    enum BootstrapError: LocalizedError {
        /// Nothing is listening on the target port at all -- the same
        /// check the real `et` client's own `ping()` performs *before*
        /// ever touching SSH, so a host with no `etserver` running fails
        /// fast with a clear message instead of paying for a full SSH
        /// round trip first.
        case serverNotReachable(host: String, port: UInt16)
        /// The SSH-run `etterminal` command didn't produce a parsable
        /// `IDPASSKEY:` reply -- not installed, not on PATH, or (per the
        /// real client's own error message for this exact case) something
        /// in the remote user's shell startup files printed extra text
        /// ahead of it.
        case noEtTerminal(detail: String)

        var errorDescription: String? {
            switch self {
            case .serverNotReachable(let host, let port):
                return "No etserver listening on \(host):\(port) -- connect over plain SSH first, or install/start etserver on this host."
            case .noEtTerminal(let detail):
                let firstLine = detail.split(whereSeparator: \.isNewline).first.map(String.init) ?? "no output"
                return "etterminal not available (\(firstLine))"
            }
        }
    }

    /// `et`'s own default (`-p,--port` in `TerminalClientMain.cpp`,
    /// `cxxopts::value<int>()->default_value("2022")`).
    static let defaultPort: UInt16 = 2022

    /// The real client reads its own shell's `$TERM` here. This app has no
    /// equivalent client-side shell -- it always negotiates this exact
    /// value for its own PTY requests (see `MoshBootstrap.termPrefix` for
    /// the same parity reasoning), so that's what's forwarded here too.
    private static let clientTerm = "xterm-256color"

    private static let idPasskeyMarker = "IDPASSKEY:"
    private static let idLength = 16
    private static let passkeyLength = 32

    /// Bare TCP connect-then-close, mirroring `et`'s own `ping()` exactly:
    /// a successful connect (even though nothing is ever sent or read) is
    /// the entire check. Run *before* touching SSH at all, same as the
    /// real client, so a host with no `etserver` running is diagnosed
    /// without an unnecessary SSH round trip.
    static func ping(host: String, port: UInt16 = defaultPort, timeout: TimeInterval = 5) async throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw BootstrapError.serverNotReachable(host: host, port: port)
        }
        let connection = NWConnection(host: .init(host), port: nwPort, using: .tcp)
        let outcome = ResumeOnce<Bool>()

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                outcome.resume(true)
            case .failed, .cancelled:
                outcome.resume(false)
            default:
                break
            }
        }
        connection.start(queue: .global())
        let timeoutTask = Task {
            try? await Task.sleep(for: .seconds(timeout))
            outcome.resume(false)
        }

        let reachable = await outcome.value()
        timeoutTask.cancel()
        connection.cancel()

        guard reachable else {
            throw BootstrapError.serverNotReachable(host: host, port: port)
        }
    }

    /// Pings the target's `etserver` port, then runs `etterminal` over
    /// `client` to register a freshly generated id/passkey. Throws
    /// `BootstrapError` for anything that just means "no ET upgrade
    /// available on this host" -- callers should treat that as a normal,
    /// expected outcome on hosts without ET, not a connection failure.
    static func detect(host: String, port: UInt16 = defaultPort, client: Citadel.SSHClient) async throws -> Result {
        try await ping(host: host, port: port)

        var idChars = Array(randomAlphanumeric(length: idLength))
        // `SetupSsh` unconditionally overwrites these three characters --
        // not a signal a server inspects, just a fixed prefix the upstream
        // comment describes as "for compatibility with old servers that do
        // not generate their own keys." See the CLAUDE.md correction this
        // type's doc comment points to for why this isn't the "mangled to
        // signal willingness" scheme an earlier pass here assumed.
        idChars[0] = "X"
        idChars[1] = "X"
        idChars[2] = "X"
        let id = String(idChars)
        let passkey = randomAlphanumeric(length: passkeyLength)

        let output = try await run(client: client, id: id, passkey: passkey)
        return try parse(output: output)
    }

    /// Runs via `executeCommandStream` (not `executeCommand`) so the
    /// accumulated output survives a non-zero exit -- same reasoning as
    /// `MoshBootstrap.run`: a missing `etterminal` is a non-zero shell exit
    /// whose *text* this needs to inspect, not just its code.
    private static func run(client: Citadel.SSHClient, id: String, passkey: String) async throws -> String {
        let command = "echo '\(id)/\(passkey)_\(clientTerm)' | etterminal --verbose=0"
        var text = ""
        do {
            let stream = try await client.executeCommandStream(command)
            for try await chunk in stream {
                switch chunk {
                case .stdout(let buffer), .stderr(let buffer):
                    text += String(buffer: buffer)
                }
            }
        } catch is Citadel.SSHClient.CommandFailed {
            // Expected when etterminal is missing (shell exit 127) or
            // fails for some other reason -- `text` still has whatever was
            // printed before exiting.
        } catch {
            throw BootstrapError.noEtTerminal(detail: String(describing: error))
        }
        return text
    }

    /// Parses `etterminal`'s combined stdout+stderr for its `IDPASSKEY:`
    /// reply. Mirrors the real client's own parse exactly
    /// (`sshBuffer.find("IDPASSKEY:")` then a **fixed-width** substring of
    /// `16 + 1 + 32` characters split on `/`, not a search for a
    /// delimiter-terminated line) -- see this type's doc comment for the
    /// CLAUDE.md correction this was grounded against. Additionally
    /// validates each half's length before returning, which the real C++
    /// does not bother to do; this only rejects a reply the real client
    /// would itself have silently mis-sliced or crashed on, it doesn't
    /// change behavior on any well-formed reply.
    static func parse(output: String) throws -> Result {
        guard let markerRange = output.range(of: idPasskeyMarker) else {
            throw BootstrapError.noEtTerminal(detail: output)
        }
        let neededLength = idLength + 1 + passkeyLength
        guard let payloadEnd = output.index(markerRange.upperBound, offsetBy: neededLength, limitedBy: output.endIndex) else {
            throw BootstrapError.noEtTerminal(detail: output)
        }
        let payload = output[markerRange.upperBound..<payloadEnd]
        let parts = payload.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == idLength, parts[1].count == passkeyLength else {
            throw BootstrapError.noEtTerminal(detail: output)
        }
        return Result(id: String(parts[0]), passkey: String(parts[1]))
    }

    /// Mirrors `genRandomAlphaNum` (`src/base/Headers.hpp`): same 62-character
    /// alphabet (`0-9A-Za-z`), same uniform-selection requirement (the
    /// upstream implementation uses libsodium's `randombytes_uniform` to
    /// avoid modulo bias; Swift's `randomElement(using:)` over a
    /// `SystemRandomNumberGenerator` -- itself CSPRNG-backed on Apple
    /// platforms -- gives the same unbiased-uniform property via its own
    /// rejection-sampling implementation).
    private static func randomAlphanumeric(length: Int) -> String {
        let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in alphabet.randomElement(using: &generator)! })
    }
}

/// A `CheckedContinuation` traps if resumed twice, but `ping(host:port:timeout:)`
/// has two independent sources that can each try to resume it -- the
/// connection's own state handler and the timeout task -- and either could
/// fire first. This serializes "whichever happens first wins, everything
/// else is silently ignored" behind a lock, the same shape `SSHConnection`
/// uses in a couple of places for its own race handling.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    private var result: T?

    func resume(_ value: T) {
        lock.lock()
        defer { lock.unlock() }
        guard result == nil else { return }
        result = value
        if let continuation {
            continuation.resume(returning: value)
            self.continuation = nil
        }
    }

    func value() async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: result)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }
}
