import Foundation
import Observation
import NIO
import NIOSSH
import Citadel
import CryptoKit

/// Holds Citadel's non-Sendable networking objects outside of
/// `SSHConnection`'s `@Observable` storage.
///
/// `nonisolated(unsafe)` on an `@Observable`-macro-generated property
/// doesn't reliably apply to the storage the macro actually synthesizes
/// (some toolchains warn "has no effect" and still treat it as
/// actor-isolated, which then fails to compile when it crosses into the
/// non-isolated `runSession` task). A plain class has no such macro
/// rewriting, so its stored properties are unambiguously nonisolated.
/// `@unchecked Sendable` is safe here in practice: writes only ever happen
/// from the single sequential `runSession` task, and reads come from
/// short, non-overlapping UI-triggered calls (`send`/`resize`/
/// `disconnect`) -- a race would at worst see a stale `nil` and no-op,
/// never corrupt memory.
private final class SSHNetworkState: @unchecked Sendable {
    var client: Citadel.SSHClient?
    var writer: TTYStdinWriter?
}

/// A single interactive SSH session backed by Citadel, feeding decoded PTY
/// output to whichever terminal view is currently displaying it.
///
/// `@unchecked Sendable`: this class is `@MainActor`-isolated, so all of its
/// mutable state is already serialized onto the main actor. The connection
/// setup and PTY read loop run in a detached, non-isolated task (Citadel's
/// own types aren't Sendable-audited), and hop back to the main actor
/// explicitly whenever they touch `state` or `onOutput` -- see
/// `runSession`.
@MainActor
@Observable
final class SSHConnection: Identifiable, Hashable, @unchecked Sendable {
    nonisolated static func == (lhs: SSHConnection, rhs: SSHConnection) -> Bool {
        lhs === rhs
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    enum State: Equatable {
        case connecting
        case connected
        case disconnected
        case failed(String)
        /// Between an unexpected drop and the next auto-reconnect attempt
        /// `reconnectWithBackoff` has scheduled, holding the `Date` that
        /// attempt will fire so the UI can show a live countdown instead of
        /// sitting on a stale "Disconnected" banner for up to 30s with no
        /// sign anything is going to happen.
        case waitingToReconnect(at: Date)

        var isDisconnectedOrFailed: Bool {
            switch self {
            case .disconnected, .failed, .waitingToReconnect: return true
            case .connecting, .connected: return false
            }
        }
    }

    let id = UUID()
    let host: SSHHost
    private(set) var state: State = .connecting

    /// Set once by `TerminalViewStore`'s persistent controller for this
    /// connection and left wired for as long as the session is open, so
    /// output arriving while no `TerminalSessionView` is on screen is still
    /// fed into that session's `SwiftTerm.TerminalView` -- not dropped.
    var onOutput: (([UInt8]) -> Void)?

    /// Called for a genuinely *unexpected* end to the session -- a network
    /// drop, the remote server closing the connection, auth failure, etc.
    /// `SessionManager` uses this to either reconnect or tear the session
    /// down entirely, depending on the auto-reconnect setting.
    ///
    /// Never fired for a user-initiated close (see `userInitiatedClose`),
    /// nor for a *clean* end to the shell session (the user typed
    /// `exit`/`logout`, or Ctrl+D) -- see `finishCleanly` in `runSession`.
    /// Auto-reconnecting the instant someone deliberately logs out would
    /// be exactly the wrong behavior.
    var onDrop: (() -> Void)?

    private let network = SSHNetworkState()
    private var userInitiatedClose = false

    /// Handle to the in-flight `connect()`/`runSession` task, so `disconnect()`
    /// can cancel a connection attempt that hasn't finished its handshake yet.
    /// Without this, closing a session while it's still "Connecting…" left the
    /// handshake running in the background with nothing watching it -- it would
    /// complete moments later, publish `.connected`, and open a PTY as if the
    /// close had never happened.
    private var connectTask: Task<Void, Never>?

    /// Handle to the pending delay scheduled by `reconnectWithBackoff`, so a
    /// `connect()` that arrives while it's still waiting (manual retry, the
    /// app coming back to the foreground, the user reopening the session)
    /// can cancel it instead of racing it -- without this, both the explicit
    /// connect and the backoff's own delayed `connect()` call could end up
    /// in flight at once.
    private var reconnectTask: Task<Void, Never>?

    /// Whether this connection has ever reached `.connected` before. Used
    /// only to decide whether a given `runSession` run is a *reconnect*
    /// (worth calling out in the scrollback) versus this session's very
    /// first connect (nothing to announce -- the terminal is empty).
    private var hasConnectedBefore = false

    /// Consecutive unexpected drops since the last successful connect,
    /// used to space out auto-reconnect attempts (`reconnectWithBackoff`)
    /// so a persistently broken host (revoked key, unreachable network)
    /// doesn't get hammered at full speed forever. Reset to 0 on connect.
    private var consecutiveFailureCount = 0
    nonisolated private static let baseReconnectDelay = Duration.seconds(1)
    nonisolated private static let maxReconnectDelay = Duration.seconds(30)

    init(host: SSHHost) {
        self.host = host
    }

    /// Reconnects after an exponentially increasing delay (1s, 2s, 4s, ...
    /// capped at `maxReconnectDelay`) based on how many unexpected drops
    /// have happened in a row. Used for auto-reconnect; `connect()` itself
    /// (manual retry, app-foreground reconnect) stays immediate.
    func reconnectWithBackoff(keyStore: KeyStore, hostKeyStore: HostKeyStore) {
        let delay = Self.backoffDelay(forFailureCount: consecutiveFailureCount)
        consecutiveFailureCount += 1
        state = .waitingToReconnect(at: Date.now.addingTimeInterval(Double(delay.components.seconds)))
        reconnectTask = Task {
            try? await Task.sleep(for: delay)
            // `Task.sleep` throws on cancellation, but that's swallowed by
            // `try?` above -- without an explicit check here, cancelling
            // `reconnectTask` (e.g. because `connect()` was called directly)
            // wouldn't actually stop this delayed connect from firing too.
            guard !Task.isCancelled else { return }
            // Don't revive a session the user explicitly closed while
            // this reconnect attempt was still waiting out its delay.
            guard !self.userInitiatedClose else { return }
            self.connect(keyStore: keyStore, hostKeyStore: hostKeyStore)
        }
    }

    nonisolated private static func backoffDelay(forFailureCount count: Int) -> Duration {
        let cappedExponent = min(count, 5) // 1,2,4,8,16,32s -> then capped at 30s anyway
        let base = Int(baseReconnectDelay.components.seconds)
        let seconds = min(base << cappedExponent, Int(maxReconnectDelay.components.seconds))
        return .seconds(seconds)
    }

    func connect(keyStore: KeyStore, hostKeyStore: HostKeyStore) {
        guard network.client == nil else { return }
        // Cancelling any pending backoff wait here (rather than just in
        // `reconnectWithBackoff`'s own delayed closure) is what actually
        // prevents a manual/foreground reconnect from racing that delayed
        // call: `Task.sleep` responds to cancellation immediately, so this
        // guarantees the backoff's own `connect()` call never fires once a
        // real one has already started.
        reconnectTask?.cancel()
        reconnectTask = nil
        userInitiatedClose = false
        let isReconnect = hasConnectedBefore
        state = .connecting

        guard let keyID = host.keyID, let key = keyStore.keys.first(where: { $0.id == keyID }) else {
            state = .failed(SSHConnectionError.noKeyConfigured.localizedDescription)
            return
        }

        let material: SSHPrivateKeyMaterial
        do {
            material = try keyStore.privateKeyMaterial(for: key, reason: "authenticate to connect to \u{201C}\(host.nickname)\u{201D}")
        } catch {
            state = .failed(error.localizedDescription)
            return
        }

        let host = self.host
        let network = self.network

        connectTask = Task.detached { [weak self] in
            await self?.runSession(host: host, material: material, hostKeyStore: hostKeyStore, network: network, isReconnect: isReconnect)
        }
    }

    /// Runs entirely off the main actor (Citadel's types aren't Sendable),
    /// hopping back to the main actor only to publish state/output.
    nonisolated private func runSession(
        host: SSHHost,
        material: SSHPrivateKeyMaterial,
        hostKeyStore: HostKeyStore,
        network: SSHNetworkState,
        isReconnect: Bool
    ) async {
        // Clears the (now-dead) client/writer so a later `connect()` --
        // whether from auto-reconnect or the user retrying -- isn't
        // blocked by `connect()`'s `network.client == nil` guard.
        func clearNetworkState() {
            network.client = nil
            network.writer = nil
        }

        // For a clean, expected end: the remote shell exited on its own
        // (e.g. the user typed `exit`/`logout`, or Ctrl+D). Auto-reconnect
        // must NOT fire here -- reconnecting right back into a fresh shell
        // the instant the user deliberately logged out would be exactly
        // the wrong behavior. Treated the same as a user-initiated
        // disconnect: publish `.disconnected`, nothing more.
        func finishCleanly() async {
            clearNetworkState()
            await MainActor.run { self.state = .disconnected }
        }

        // For a genuine unexpected drop or failure (network blip, auth
        // failure, host key rejected, nonzero shell exit code, etc.):
        // publishes state and fires `onDrop` so SessionManager can
        // reconnect-or-kill per the auto-reconnect setting, unless this
        // was itself the result of an explicit `disconnect()` call.
        func finishWithDrop(_ newState: State) async {
            clearNetworkState()
            await MainActor.run {
                self.state = newState
                if !self.userInitiatedClose {
                    self.onDrop?()
                }
            }
        }

        // Citadel/NIOSSH don't log the handshake internals at all (no key
        // exchange, algorithm negotiation, or auth-attempt logging exists
        // to tap into), so this can't show real protocol-level detail the
        // way `ssh -v` does. Instead it narrates the lifecycle steps we do
        // control, in the same "debug1:"-prefixed style, fed through
        // `onOutput` so it appears as regular terminal scrollback -- on by
        // default (Settings > Verbose Connecting), matching how `ssh -v`
        // always writes to the same terminal rather than a separate log
        // view.
        func emitDiagnostic(_ line: String) async {
            guard UserDefaults.standard.verboseConnectingEnabled else { return }
            await MainActor.run { self.onOutput?(Array((line + "\r\n").utf8)) }
        }

        // Unlike `emitDiagnostic`, this isn't gated by Verbose Connecting --
        // it's not `ssh -v`-style detail, it's the one thing that must
        // always be visible: new output is about to land in this session's
        // scrollback that has nothing to do with whatever was on screen
        // before. Scrollback is deliberately never cleared on reconnect
        // (see CLAUDE.md), so without a marker like this a dropped
        // connection reconnecting silently would make a brand new login
        // banner just appear out of nowhere, mid-scrollback, with zero
        // explanation. The leading "\r\n" also guarantees this (and
        // whatever follows it) starts on its own fresh line even if the
        // previous output didn't end in a newline.
        if isReconnect {
            await MainActor.run {
                self.onOutput?(Array("\r\n[ssssh] Reconnecting to \u{201C}\(host.nickname)\u{201D}…\r\n".utf8))
            }
        }

        do {
            await emitDiagnostic("debug1: Connecting to \(host.hostname) port \(host.port).")

            let auth = Self.makeAuthenticationMethod(username: host.username, material: material)
            let validator = SSHHostKeyValidator.tofu(host: host, hostKeyStore: hostKeyStore)

            let client = try await Citadel.SSHClient.connect(
                host: host.hostname,
                port: host.port,
                authenticationMethod: auth,
                hostKeyValidator: validator,
                reconnect: .never
            )
            network.client = client

            // The handshake above has no cancellation checks of its own, so a
            // `disconnect()` that arrived while it was in flight (e.g. closing
            // a session that's still "Connecting…") has nothing to close yet
            // and can only cancel this task. Check for that now, before
            // publishing `.connected` and opening a PTY the user already
            // asked to close.
            guard !Task.isCancelled else {
                clearNetworkState()
                try? await client.close()
                return
            }

            await emitDiagnostic("debug1: Authentication succeeded (\(Self.algorithmDescription(for: material))) for user '\(host.username)'.")
            await MainActor.run {
                self.state = .connected
                self.consecutiveFailureCount = 0
                self.hasConnectedBefore = true
            }

            let ptyRequest = SSHChannelRequestEvent.PseudoTerminalRequest(
                wantReply: true,
                term: "xterm-256color",
                terminalCharacterWidth: 80,
                terminalRowHeight: 24,
                terminalPixelWidth: 0,
                terminalPixelHeight: 0,
                terminalModes: SSHTerminalModes([:])
            )
            await emitDiagnostic("debug1: Requesting pty (xterm-256color, 80x24).")

            do {
                try await client.withPTY(ptyRequest) { inbound, outbound in
                    network.writer = outbound
                    if let startupCommand = host.startupCommand, !startupCommand.isEmpty {
                        try? await outbound.write(ByteBuffer(string: startupCommand + "\n"))
                    }
                    for try await chunk in inbound {
                        switch chunk {
                        case .stdout(let buffer), .stderr(let buffer):
                            let bytes = Array(buffer.readableBytesView)
                            await MainActor.run { self.onOutput?(bytes) }
                        }
                    }
                }
                await finishCleanly()
            } catch let error as NIO.ChannelError where error == .alreadyClosed {
                // Citadel's withPTY tries to close the channel again on the
                // way out; if the remote end already hung up (e.g. the user
                // typed `exit`), that second close throws this. It's not a
                // real failure -- verified against a real server where the
                // PTY session completed successfully and only the trailing
                // close-after-close raised this. Same as the clean-exit
                // case above: no auto-reconnect.
                await finishCleanly()
            } catch {
                let message = Self.describe(error)
                await emitDiagnostic("debug1: \(message)")
                await finishWithDrop(.failed(message))
            }
        } catch {
            let message = Self.describe(error)
            await emitDiagnostic("debug1: \(message)")
            await finishWithDrop(.failed(message))
        }
    }

    func send(_ bytes: [UInt8]) {
        guard let writer = network.writer else { return }
        let buffer = ByteBuffer(bytes: bytes)
        Task { try? await writer.write(buffer) }
    }

    /// Last size this connection told the remote PTY about, defaulting to
    /// the size requested at connect time (see `ptyRequest` in
    /// `runSession`). Used by `sendKeepalive()` to re-send a size the
    /// terminal view may never have actually changed.
    private var lastKnownSize: (cols: Int, rows: Int) = (80, 24)

    func resize(cols: Int, rows: Int) {
        guard let writer = network.writer, cols > 0, rows > 0 else { return }
        lastKnownSize = (cols, rows)
        Task { try? await writer.changeSize(cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0) }
    }

    /// Re-sends the last known terminal size as a harmless keepalive.
    /// `SessionManager` calls this on a timer while the app is
    /// backgrounded so an idle-timing-out NAT or firewall along the way
    /// doesn't consider the TCP connection dead during the up-to-five-
    /// minute background window -- see
    /// `SessionManager.applicationDidEnterBackground()`. Resending the
    /// *same* size is a genuine wire message (a `WindowChangeRequest`) but
    /// a no-op to any well-behaved shell, since the size hasn't changed.
    func sendKeepalive() {
        resize(cols: lastKnownSize.cols, rows: lastKnownSize.rows)
    }

    func disconnect() {
        userInitiatedClose = true
        consecutiveFailureCount = 0
        reconnectTask?.cancel()
        reconnectTask = nil
        connectTask?.cancel()
        connectTask = nil
        let client = network.client
        network.client = nil
        network.writer = nil
        state = .disconnected
        Task { try? await client?.close() }
    }

    nonisolated private static func makeAuthenticationMethod(username: String, material: SSHPrivateKeyMaterial) -> SSHAuthenticationMethod {
        switch material {
        case .ed25519(let privateKey):
            return .ed25519(username: username, privateKey: privateKey)
        case .ecdsaP256(let privateKey):
            return .p256(username: username, privateKey: privateKey)
        case .ecdsaP384(let privateKey):
            return .p384(username: username, privateKey: privateKey)
        }
    }

    nonisolated private static func algorithmDescription(for material: SSHPrivateKeyMaterial) -> String {
        switch material {
        case .ed25519: return "publickey: ssh-ed25519"
        case .ecdsaP256: return "publickey: ecdsa-sha2-nistp256"
        case .ecdsaP384: return "publickey: ecdsa-sha2-nistp384"
        }
    }

    nonisolated private static func describe(_ error: Error) -> String {
        if error is HostKeyRejected {
            return "Host key was not trusted."
        }
        if let mismatch = error as? HostKeyMismatch {
            return "Host key changed for \(mismatch.hostNickname)! Expected \(mismatch.expected) but got \(mismatch.presented). This could mean someone is intercepting your connection."
        }
        return error.localizedDescription
    }
}

enum SSHConnectionError: LocalizedError {
    case noKeyConfigured

    var errorDescription: String? {
        switch self {
        case .noKeyConfigured:
            return "This host has no key configured. Edit the host and choose a key."
        }
    }
}

private extension UserDefaults {
    /// Defaults to `true` (verbose by default, matching `ssh -v`-style
    /// connecting output) when the user has never touched the setting.
    var verboseConnectingEnabled: Bool {
        object(forKey: AppSettingsKeys.verboseConnecting) == nil || bool(forKey: AppSettingsKeys.verboseConnecting)
    }
}
