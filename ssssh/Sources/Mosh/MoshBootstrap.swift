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

    /// A plain `mosh-server new -s` SSH exec request runs non-interactively
    /// and non-login (Citadel's `executeCommand`, like a real SSH "exec"
    /// channel request generally, invokes the remote shell as `$SHELL -c
    /// "..."`, not `$SHELL -lc "..."`). On macOS that means `~/.zprofile`
    /// -- where Homebrew's installer adds its `brew shellenv` PATH line --
    /// is never sourced, so `mosh-server` installed at `/opt/homebrew/bin`
    /// (Apple Silicon) or `/usr/local/bin` (Intel) is invisible even though
    /// it's genuinely installed and on the *interactive* login PATH.
    /// Confirmed directly against this exact shell (`env -i zsh -c 'echo
    /// $PATH'` omits `/opt/homebrew/bin`; `zsh -lc` includes it only
    /// because `.zprofile` sources `brew shellenv`). Prepending these
    /// well-known install locations to PATH sidesteps the whole
    /// login-shell-sourcing question rather than depending on it --
    /// harmless no-ops on hosts that don't have them.
    private static let pathPrefix = "PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin:/home/linuxbrew/.linuxbrew/bin\""

    /// A non-interactive SSH exec session doesn't necessarily carry any
    /// locale environment at all (confirmed directly: a maximally bare
    /// shell environment leaves `mosh-server` refusing to start with
    /// "needs a UTF-8 native locale to run", even though `mosh-server`
    /// itself is present and working). The real mosh client solves this by
    /// forwarding the *client's own* locale to the server via repeated
    /// `-l NAME=VALUE` flags on `mosh-server new`; this app has no
    /// equivalent client-side locale to forward (it's a generic terminal
    /// app, not tied to one), so this only reaches for a hardcoded
    /// `en_US.UTF-8` as a last resort -- see `detect(client:)`, which tries
    /// without this first so a host with its own working (and possibly
    /// differently-configured, e.g. non-English) locale is never
    /// needlessly overridden.
    private static let utf8LocaleFallback = "-l LANG=en_US.UTF-8 -l LC_ALL=en_US.UTF-8"

    /// Not `private` so it's directly testable -- the actual text this
    /// matches against comes from `mosh-server`'s own C++ source
    /// (`src/frontend/mosh-server.cc`), confirmed by triggering the real
    /// message in a deliberately bare shell environment, not guessed.
    static func needsUTF8LocaleFallback(_ output: String) -> Bool {
        output.contains("needs a UTF-8 native locale")
    }

    /// Runs `mosh-server new` on the given client and parses its reply.
    /// Throws `BootstrapError.noMoshServer` for anything that just means
    /// "no mosh upgrade available on this host" (not installed, command
    /// failed, unparsable output) -- callers should treat that as a normal,
    /// expected outcome on hosts without mosh, not a connection failure.
    ///
    /// Tries the plain command first and only retries with a forced
    /// `en_US.UTF-8` locale if that specific failure is what came back --
    /// see `utf8LocaleFallback`'s doc comment for why this isn't just
    /// always added.
    static func detect(client: Citadel.SSHClient) async throws -> Result {
        let firstAttempt = try await run(client: client, extraArguments: "")
        if let result = try? parse(output: firstAttempt) {
            return result
        }
        guard needsUTF8LocaleFallback(firstAttempt) else {
            throw BootstrapError.noMoshServer(detail: firstAttempt)
        }

        let secondAttempt = try await run(client: client, extraArguments: " \(utf8LocaleFallback)")
        return try parse(output: secondAttempt)
    }

    /// Runs the command via `executeCommandStream` (not the simpler
    /// `executeCommand`) specifically so the accumulated output survives a
    /// non-zero exit: `executeCommand` discards its own internal buffer
    /// when the command fails, surfacing only `SSHClient.CommandFailed`'s
    /// bare exit code -- and both a missing `mosh-server` (shell exit 127)
    /// and its own locale check failing (`mosh-server` exit 1) are
    /// non-zero exits whose *text* this needs to inspect, not just their
    /// code.
    private static func run(client: Citadel.SSHClient, extraArguments: String) async throws -> String {
        var text = ""
        do {
            let stream = try await client.executeCommandStream("\(pathPrefix) mosh-server new -s\(extraArguments)")
            for try await chunk in stream {
                switch chunk {
                case .stdout(let buffer), .stderr(let buffer):
                    text += String(buffer: buffer)
                }
            }
        } catch is Citadel.SSHClient.CommandFailed {
            // Expected for both failure modes above -- `text` still has
            // whatever the command printed before exiting, which is
            // exactly what the caller needs to decide what happened.
        } catch {
            throw BootstrapError.noMoshServer(detail: String(describing: error))
        }
        return text
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
