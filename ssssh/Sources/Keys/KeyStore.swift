import Foundation
import Observation

/// Owns the list of key metadata (`SSHKey`) and the Keychain-backed private
/// key material behind each one. Metadata is persisted as JSON under the
/// app's Application Support directory; private key bytes never leave the
/// Keychain.
@Observable
final class KeyStore {
    private(set) var keys: [SSHKey] = []

    private let metadataURL: URL

    init(metadataURL: URL = KeyStore.defaultMetadataURL()) {
        self.metadataURL = metadataURL
        load()
    }

    func generateKey(label: String, algorithm: SSHKeyAlgorithm = .ed25519) throws -> SSHKey {
        try persist(KeyGenerator.generate(algorithm: algorithm, comment: label), label: label)
    }

    /// Imports an existing Ed25519 private key (see `KeyImporter`) and
    /// stores it exactly the way a generated one is -- Keychain-protected,
    /// indistinguishable from a generated key from this point on.
    func importKey(label: String, fileContents: Data, passphrase: String) throws -> SSHKey {
        try persist(try KeyImporter.importEd25519(fileContents: fileContents, passphrase: passphrase, comment: label), label: label)
    }

    private func persist(_ generated: KeyGenerator.GeneratedKey, label: String) throws -> SSHKey {
        let key = SSHKey(
            id: UUID(),
            label: label,
            algorithm: generated.algorithm,
            createdAt: Date(),
            publicKeyOpenSSH: generated.publicKeyOpenSSH,
            deployedHostIDs: []
        )
        try Keychain.save(tag: key.keychainTag, data: generated.privateKeyData)
        keys.append(key)
        try save()
        return key
    }

    func delete(_ key: SSHKey) throws {
        try Keychain.delete(tag: key.keychainTag)
        keys.removeAll { $0.id == key.id }
        try save()
    }

    /// Reconstitutes the private key material for authenticating with `key`.
    /// `reason` is shown in the Face ID/passcode prompt Keychain access
    /// triggers -- pass something specific (e.g. the host being connected
    /// to) so an unattended auto-reconnect's prompt isn't a mystery.
    func privateKeyMaterial(for key: SSHKey, reason: String? = nil) throws -> SSHPrivateKeyMaterial {
        let data = try Keychain.load(tag: key.keychainTag, reason: reason ?? "authenticate to use \u{201C}\(key.label)\u{201D}")
        return try SSHPrivateKeyMaterial(algorithm: key.algorithm, rawRepresentation: data)
    }

    /// Records that `key` has been deployed to `hostID` (best-effort; used by
    /// the key detail view and the copy-to-server flow).
    func markDeployed(_ key: SSHKey, to hostID: UUID) throws {
        guard let index = keys.firstIndex(where: { $0.id == key.id }) else { return }
        if !keys[index].deployedHostIDs.contains(hostID) {
            keys[index].deployedHostIDs.append(hostID)
            try save()
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: metadataURL) else { return }
        keys = (try? JSONDecoder().decode([SSHKey].self, from: data)) ?? []
    }

    private func save() throws {
        let data = try JSONEncoder().encode(keys)
        try data.write(to: metadataURL, options: .atomic)
    }

    private static func defaultMetadataURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("keys.json")
    }
}
