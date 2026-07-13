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

        var isDisconnectedOrFailed: Bool {
            switch self {
            case .disconnected, .failed: return true
            case .connecting, .connected: return false
            }
        }
    }

    let id = UUID()
    let host: SSHHost
    private(set) var state: State = .connecting

    /// Set by whichever `TerminalSessionView` is on screen for this
    /// connection; cleared when it disappears. Output arriving while no
    /// view is attached is dropped (the session itself keeps running).
    var onOutput: (([UInt8]) -> Void)?

    /// Called when the session ends for any reason *other* than an
    /// explicit `disconnect()` call -- a network drop, the remote server
    /// closing the connection, auth failure, etc. `SessionManager` uses
    /// this to either reconnect or tear the session down entirely,
    /// depending on the auto-reconnect setting. Never fired for a
    /// user-initiated close (see `userInitiatedClose`).
    var onDrop: (() -> Void)?

    private let network = SSHNetworkState()
    private var userInitiatedClose = false

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
        Task {
            try? await Task.sleep(for: delay)
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
        userInitiatedClose = false
        state = .connecting

        guard let keyID = host.keyID, let key = keyStore.keys.first(where: { $0.id == keyID }) else {
            state = .failed(SSHConnectionError.noKeyConfigured.localizedDescription)
            return
        }

        let material: SSHPrivateKeyMaterial
        do {
            material = try keyStore.privateKeyMaterial(for: key)
        } catch {
            state = .failed(error.localizedDescription)
            return
        }

        let host = self.host
        let network = self.network

        Task.detached { [weak self] in
            await self?.runSession(host: host, material: material, hostKeyStore: hostKeyStore, network: network)
        }
    }

    /// Runs entirely off the main actor (Citadel's types aren't Sendable),
    /// hopping back to the main actor only to publish state/output.
    nonisolated private func runSession(
        host: SSHHost,
        material: SSHPrivateKeyMaterial,
        hostKeyStore: HostKeyStore,
        network: SSHNetworkState
    ) async {
        // Clears the (now-dead) client/writer so a later `connect()` --
        // whether from auto-reconnect or the user retrying -- isn't
        // blocked by `connect()`'s `network.client == nil` guard, then
        // publishes the final state and fires `onDrop` unless this was an
        // explicit `disconnect()`.
        func finish(_ newState: State) async {
            network.client = nil
            network.writer = nil
            await MainActor.run {
                self.state = newState
                if !self.userInitiatedClose {
                    self.onDrop?()
                }
            }
        }

        do {
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
            await MainActor.run {
                self.state = .connected
                self.consecutiveFailureCount = 0
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
                await finish(.disconnected)
            } catch let error as NIO.ChannelError where error == .alreadyClosed {
                // Citadel's withPTY tries to close the channel again on the
                // way out; if the remote end already hung up (e.g. the user
                // typed `exit`), that second close throws this. It's not a
                // real failure -- verified against a real server where the
                // PTY session completed successfully and only the trailing
                // close-after-close raised this.
                await finish(.disconnected)
            } catch {
                await finish(.failed(Self.describe(error)))
            }
        } catch {
            await finish(.failed(Self.describe(error)))
        }
    }

    func send(_ bytes: [UInt8]) {
        guard let writer = network.writer else { return }
        let buffer = ByteBuffer(bytes: bytes)
        Task { try? await writer.write(buffer) }
    }

    func resize(cols: Int, rows: Int) {
        guard let writer = network.writer, cols > 0, rows > 0 else { return }
        Task { try? await writer.changeSize(cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0) }
    }

    func disconnect() {
        userInitiatedClose = true
        consecutiveFailureCount = 0
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
