import Foundation

enum SSHKeyAlgorithm: String, Codable, CaseIterable {
    case ed25519
    case ecdsaP256
    case ecdsaP384
    case rsa // import-only; not offered in the key-generation UI

    var displayName: String {
        switch self {
        case .ed25519: return "Ed25519"
        case .ecdsaP256: return "ECDSA (P-256)"
        case .ecdsaP384: return "ECDSA (P-384)"
        case .rsa: return "RSA"
        }
    }
}

/// Metadata for a key pair whose private key material lives in the Keychain.
/// See `KeyStore` for the Keychain-backed storage this references.
struct SSHKey: Identifiable, Codable, Hashable {
    let id: UUID
    var label: String
    var algorithm: SSHKeyAlgorithm
    var createdAt: Date
    var publicKeyOpenSSH: String
    var deployedHostIDs: [UUID]

    /// Key used to look up the private key in the Keychain.
    var keychainTag: String { "com.smerwin.ssssh.key.\(id.uuidString)" }
}
