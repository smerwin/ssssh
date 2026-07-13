import Foundation
import NIO
import Citadel

/// Implements the "copy key to server" flow described in the README:
/// authenticate once with a password, then ensure `~/.ssh/authorized_keys`
/// on the remote host contains the given public key, creating `~/.ssh`
/// with `0700` and the file with `0600` if needed. The password is held
/// only in memory for the duration of the call and is never persisted.
///
/// The key line is shipped base64-encoded and decoded remotely into a
/// shell variable, so nothing about its contents needs shell-escaping.
///
/// Takes the already-resolved public key string and private key material
/// (rather than `SSHKey`/`KeyStore`) so callers can look those up on the
/// main actor first -- `KeyStore` isn't Sendable, and this whole flow runs
/// off the main actor since Citadel's types aren't Sendable-audited either.
enum SSHCopyID {
    static func copyKey(
        publicKeyOpenSSH: String,
        material: SSHPrivateKeyMaterial,
        to host: SSHHost,
        password: String,
        hostKeyStore: HostKeyStore
    ) async throws {
        let validator = SSHHostKeyValidator.tofu(host: host, hostKeyStore: hostKeyStore)
        let passwordClient = try await Citadel.SSHClient.connect(
            host: host.hostname,
            port: host.port,
            authenticationMethod: .passwordBased(username: host.username, password: password),
            hostKeyValidator: validator,
            reconnect: .never
        )

        do {
            let encodedKey = Data(publicKeyOpenSSH.utf8).base64EncodedString()
            let command = """
            mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && \
            KEY=$(echo \(encodedKey) | base64 -d) && grep -qxF "$KEY" ~/.ssh/authorized_keys || echo "$KEY" >> ~/.ssh/authorized_keys
            """
            _ = try await passwordClient.executeCommand(command, mergeStreams: true)
        } catch {
            try? await passwordClient.close()
            throw error
        }

        try await passwordClient.close()

        // Confirm the key actually works before declaring success.
        let auth: SSHAuthenticationMethod
        switch material {
        case .ed25519(let privateKey):
            auth = .ed25519(username: host.username, privateKey: privateKey)
        case .ecdsaP256(let privateKey):
            auth = .p256(username: host.username, privateKey: privateKey)
        case .ecdsaP384(let privateKey):
            auth = .p384(username: host.username, privateKey: privateKey)
        }

        let confirmingClient = try await Citadel.SSHClient.connect(
            host: host.hostname,
            port: host.port,
            authenticationMethod: auth,
            hostKeyValidator: validator,
            reconnect: .never
        )
        try await confirmingClient.close()
    }
}
