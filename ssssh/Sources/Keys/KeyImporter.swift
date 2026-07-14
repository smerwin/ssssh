import Foundation
import CryptoKit
import Citadel

/// Imports an existing Ed25519 private key from OpenSSH's standard
/// `-----BEGIN OPENSSH PRIVATE KEY-----` armored format -- the format
/// `ssh-keygen` produces by default.
///
/// RSA and ECDSA P-256/P-384 import aren't supported: see the "Importing
/// RSA/ECDSA private keys" note in CLAUDE.md for exactly why, and what it
/// would take to add.
enum KeyImporter {
    enum ImportError: LocalizedError {
        case unsupportedAlgorithm(String)
        case invalidKey(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedAlgorithm(let type):
                return "ssssh can only import Ed25519 keys right now, not \(type)."
            case .invalidKey(let reason):
                return reason
            }
        }
    }

    static func importEd25519(fileContents: Data, passphrase: String, comment: String) throws -> KeyGenerator.GeneratedKey {
        guard let text = String(data: fileContents, encoding: .utf8) else {
            throw ImportError.invalidKey("That file isn't readable as text.")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        let detected: SSHKeyType
        do {
            detected = try SSHKeyDetection.detectPrivateKeyType(from: trimmed)
        } catch {
            throw ImportError.invalidKey("That doesn't look like an OpenSSH private key.")
        }
        guard detected == .ed25519 else {
            throw ImportError.unsupportedAlgorithm(detected.description)
        }

        let decryptionKey = passphrase.isEmpty ? nil : Data(passphrase.utf8)
        let privateKey: Curve25519.Signing.PrivateKey
        do {
            privateKey = try Curve25519.Signing.PrivateKey(sshEd25519: trimmed, decryptionKey: decryptionKey)
        } catch {
            throw ImportError.invalidKey(
                passphrase.isEmpty
                    ? "Couldn't decrypt this key. It may be passphrase-protected."
                    : "Couldn't decrypt this key. Check the passphrase and try again."
            )
        }

        let publicKeyLine = KeyGenerator.openSSHLine(
            keyType: "ssh-ed25519",
            publicKeyBytes: privateKey.publicKey.rawRepresentation,
            comment: comment
        )
        return KeyGenerator.GeneratedKey(
            algorithm: .ed25519,
            privateKeyData: privateKey.rawRepresentation,
            publicKeyOpenSSH: publicKeyLine
        )
    }
}
