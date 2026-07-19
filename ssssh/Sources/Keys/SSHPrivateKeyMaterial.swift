import Foundation
import CryptoKit
import Citadel

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

    /// The `Citadel.SSHAuthenticationMethod` for authenticating as `username`
    /// with this key.
    func authenticationMethod(username: String) -> SSHAuthenticationMethod {
        switch self {
        case .ed25519(let privateKey):
            return .ed25519(username: username, privateKey: privateKey)
        case .ecdsaP256(let privateKey):
            return .p256(username: username, privateKey: privateKey)
        case .ecdsaP384(let privateKey):
            return .p384(username: username, privateKey: privateKey)
        }
    }

    /// A short `debug1`-style description of this key's algorithm, used in
    /// verbose-connecting diagnostics.
    var algorithmDescription: String {
        switch self {
        case .ed25519: return "publickey: ssh-ed25519"
        case .ecdsaP256: return "publickey: ecdsa-sha2-nistp256"
        case .ecdsaP384: return "publickey: ecdsa-sha2-nistp384"
        }
    }
}
