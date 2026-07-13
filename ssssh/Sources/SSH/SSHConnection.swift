import Foundation
import Observation
import NIO
import NIOSSH
import Citadel
import CryptoKit

/// A single interactive SSH session backed by Citadel, feeding decoded PTY
/// output to whichever terminal view is currently displaying it.
///
/// `@unchecked Sendable`: this class is `@MainActor`-isolated, so all of its
/// mutable state is already serialized onto the main actor. The connection
/// setup and PTY read loop run in a detached, non-isolated task (Citadel's
/// own types aren't Sendable-audited), and hop back to the main actor
/// explicitly whenever they touch `state`, `client`, `writer`, or
/// `onOutput` -- see `runSession`.
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

    // Citadel's types aren't Sendable-audited, so these can't live in
    // main-actor-isolated storage without forcing every touch through a
    // `MainActor.run` hop. They're only ever written from the single
    // sequential `runSession` task and read from short, non-overlapping
    // UI-triggered calls (`send`/`resize`/`disconnect`), so unchecked
    // isolation is safe here in practice: a race would at worst see a
    // stale `nil` and no-op, never corrupt memory.
    private nonisolated(unsafe) var client: Citadel.SSHClient?
    private nonisolated(unsafe) var writer: TTYStdinWriter?

    init(host: SSHHost) {
        self.host = host
    }

    func connect(keyStore: KeyStore, hostKeyStore: HostKeyStore) {
        guard client == nil else { return }
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

        Task.detached { [weak self] in
            await self?.runSession(host: host, material: material, hostKeyStore: hostKeyStore)
        }
    }

    /// Runs entirely off the main actor (Citadel's types aren't Sendable),
    /// hopping back to the main actor only to publish state/output.
    nonisolated private func runSession(
        host: SSHHost,
        material: SSHPrivateKeyMaterial,
        hostKeyStore: HostKeyStore
    ) async {
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
            self.client = client
            await MainActor.run { self.state = .connected }

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
                    self.writer = outbound
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
                await MainActor.run { self.state = .disconnected }
            } catch let error as NIO.ChannelError where error == .alreadyClosed {
                // Citadel's withPTY tries to close the channel again on the
                // way out; if the remote end already hung up (e.g. the user
                // typed `exit`), that second close throws this. It's not a
                // real failure -- verified against a real server where the
                // PTY session completed successfully and only the trailing
                // close-after-close raised this.
                await MainActor.run { self.state = .disconnected }
            } catch {
                await MainActor.run { self.state = .failed(Self.describe(error)) }
            }
        } catch {
            await MainActor.run { self.state = .failed(Self.describe(error)) }
        }
    }

    func send(_ bytes: [UInt8]) {
        guard let writer else { return }
        let buffer = ByteBuffer(bytes: bytes)
        Task { try? await writer.write(buffer) }
    }

    func resize(cols: Int, rows: Int) {
        guard let writer, cols > 0, rows > 0 else { return }
        Task { try? await writer.changeSize(cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0) }
    }

    func disconnect() {
        let client = self.client
        self.client = nil
        self.writer = nil
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
