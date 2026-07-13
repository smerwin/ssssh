import Foundation
import CryptoKit

/// Generates key pairs on-device and formats public keys as standard
/// OpenSSH authorized_keys lines. RSA is import-only (see `SSHKeyAlgorithm`)
/// and has no generator here.
enum KeyGenerator {
    struct GeneratedKey {
        let algorithm: SSHKeyAlgorithm
        let privateKeyData: Data
        let publicKeyOpenSSH: String
    }

    static func generate(algorithm: SSHKeyAlgorithm, comment: String) -> GeneratedKey {
        switch algorithm {
        case .ed25519:
            return generateEd25519(comment: comment)
        case .ecdsaP256:
            return generateECDSAP256(comment: comment)
        case .ecdsaP384:
            return generateECDSAP384(comment: comment)
        case .rsa:
            fatalError("RSA is import-only; there is no generator for it")
        }
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

    static func generateECDSAP256(comment: String) -> GeneratedKey {
        let privateKey = P256.Signing.PrivateKey()
        let publicKeyLine = openSSHLine(
            keyType: "ecdsa-sha2-nistp256",
            publicKeyBytes: ecdsaWireBody(curveIdentifier: "nistp256", x963: privateKey.publicKey.x963Representation),
            comment: comment,
            rawField: true
        )
        return GeneratedKey(
            algorithm: .ecdsaP256,
            privateKeyData: privateKey.rawRepresentation,
            publicKeyOpenSSH: publicKeyLine
        )
    }

    static func generateECDSAP384(comment: String) -> GeneratedKey {
        let privateKey = P384.Signing.PrivateKey()
        let publicKeyLine = openSSHLine(
            keyType: "ecdsa-sha2-nistp384",
            publicKeyBytes: ecdsaWireBody(curveIdentifier: "nistp384", x963: privateKey.publicKey.x963Representation),
            comment: comment,
            rawField: true
        )
        return GeneratedKey(
            algorithm: .ecdsaP384,
            privateKeyData: privateKey.rawRepresentation,
            publicKeyOpenSSH: publicKeyLine
        )
    }

    /// ECDSA OpenSSH keys wire-encode as `curve-identifier-string` followed by
    /// the uncompressed point (the CryptoKit x963 representation), unlike
    /// Ed25519 which is just the raw 32-byte key.
    private static func ecdsaWireBody(curveIdentifier: String, x963: Data) -> Data {
        var body = Data()
        body.append(lengthPrefixed: Data(curveIdentifier.utf8))
        body.append(lengthPrefixed: x963)
        return body
    }

    /// Builds an OpenSSH wire-format blob and wraps it as a base64
    /// `authorized_keys` line, e.g.
    /// `ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... label`.
    ///
    /// `rawField` controls whether `publicKeyBytes` is itself already a
    /// sequence of length-prefixed fields (ECDSA) or a single field that
    /// still needs a length prefix (Ed25519).
    private static func openSSHLine(keyType: String, publicKeyBytes: Data, comment: String, rawField: Bool = false) -> String {
        var blob = Data()
        blob.append(lengthPrefixed: Data(keyType.utf8))
        if rawField {
            blob.append(publicKeyBytes)
        } else {
            blob.append(lengthPrefixed: publicKeyBytes)
        }
        let base64 = blob.base64EncodedString()
        return "\(keyType) \(base64) \(comment)"
    }
}

extension Data {
    mutating func append(lengthPrefixed field: Data) {
        var length = UInt32(field.count).bigEndian
        append(Data(bytes: &length, count: 4))
        append(field)
    }
}
