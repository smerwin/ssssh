import Foundation
import CryptoKit

/// Generates key pairs on-device and formats public keys as standard
/// OpenSSH authorized_keys lines. Only Ed25519 is implemented so far;
/// ECDSA support lands alongside real SSH auth in the connect milestone.
enum KeyGenerator {
    struct GeneratedKey {
        let algorithm: SSHKeyAlgorithm
        let privateKeyData: Data
        let publicKeyOpenSSH: String
    }

    static func generateEd25519(comment: String) -> GeneratedKey {
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKeyLine = openSSHLine(
            keyType: "ssh-ed25519",
            publicKeyBytes: privateKey.publicKey.rawRepresentation,
            comment: comment
        )
        return GeneratedKey(
            algorithm: .ed25519,
            privateKeyData: privateKey.rawRepresentation,
            publicKeyOpenSSH: publicKeyLine
        )
    }

    /// Builds an OpenSSH wire-format blob (length-prefixed fields) and
    /// wraps it as a base64 `authorized_keys` line, e.g.
    /// `ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... label`.
    private static func openSSHLine(keyType: String, publicKeyBytes: Data, comment: String) -> String {
        var blob = Data()
        blob.append(lengthPrefixed: Data(keyType.utf8))
        blob.append(lengthPrefixed: publicKeyBytes)
        let base64 = blob.base64EncodedString()
        return "\(keyType) \(base64) \(comment)"
    }
}

private extension Data {
    mutating func append(lengthPrefixed field: Data) {
        var length = UInt32(field.count).bigEndian
        append(Data(bytes: &length, count: 4))
        append(field)
    }
}
