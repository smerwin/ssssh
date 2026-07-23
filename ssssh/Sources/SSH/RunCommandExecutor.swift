import Foundation
import Citadel

/// Runs a single command over a one-shot Citadel connection and returns its
/// combined stdout+stderr text. This is the entire SSH interaction behind
/// the "Run Command" Shortcuts intent (`RunCommandIntent`) -- deliberately
/// not `SSHConnection`/`SessionManager`'s live-terminal state machine. See
/// `SSHCopyID`'s doc comment for why this takes pre-resolved
/// `SSHPrivateKeyMaterial` rather than `KeyStore`/`SSHKey` directly:
/// `KeyStore` isn't Sendable, and this whole flow runs off the main actor
/// since Citadel's types aren't Sendable-audited either.
///
/// Uses `executeCommandStream`, not `executeCommand`, for the same reason
/// `MoshBootstrap.run` does: `Citadel.SSHClient.CommandFailed` only carries
/// an exit code, and the whole point of Run Command is returning the
/// command's actual output even when it exits non-zero.
enum RunCommandExecutor {
    static func run(
        command: String,
        material: SSHPrivateKeyMaterial,
        on host: SSHHost,
        hostKeyStore: HostKeyStore
    ) async throws -> String {
        let validator = SSHHostKeyValidator.tofu(host: host, hostKeyStore: hostKeyStore)
        let client = try await Citadel.SSHClient.connect(
            to: host,
            authenticationMethod: material.authenticationMethod(username: host.username),
            hostKeyValidator: validator
        )

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
            // Same as `MoshBootstrap.run`: a non-zero exit still carries
            // real output worth returning, not just a discarded exit code.
        }
        try? await client.close()
        return text
    }
}
