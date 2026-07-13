import Foundation
import CryptoKit

/// A private key reconstituted from Keychain bytes, typed so callers can
/// hand it straight to `SSHAuthenticationMethod` without re-parsing.
enum SSHPrivateKeyMaterial {
    case ed25519(Curve25519.Signing.PrivateKey)
    case ecdsaP256(P256.Signing.PrivateKey)
    case ecdsaP384(P384.Signing.PrivateKey)

    init(algorithm: SSHKeyAlgorithm, rawRepresentation data: Data) throws {
        switch algorithm {
        case .ed25519:
            self = .ed25519(try Curve25519.Signing.PrivateKey(rawRepresentation: data))
        case .ecdsaP256:
            self = .ecdsaP256(try P256.Signing.PrivateKey(rawRepresentation: data))
        case .ecdsaP384:
            self = .ecdsaP384(try P384.Signing.PrivateKey(rawRepresentation: data))
        case .rsa:
            throw CocoaError(.featureUnsupported)
        }
    }
}
