import Foundation
import Observation

/// Owns the list of key metadata (`SSHKey`) and the Keychain-backed private
/// key material behind each one. Metadata is persisted as JSON under the
/// app's Application Support directory; private key bytes never leave the
/// Keychain.
@Observable
final class KeyStore {
    private(set) var keys: [SSHKey] = []

    private let fileStore: JSONFileStore<[SSHKey]>

    init(metadataURL: URL = applicationSupportURL(filename: "keys.json")) {
        fileStore = JSONFileStore(url: metadataURL)
        keys = fileStore.load(default: [])
    }

    func key(id: UUID) -> SSHKey? {
        keys.first { $0.id == id }
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
        do {
            try save()
        } catch {
            // Roll back so a metadata-write failure (e.g. disk full)
            // doesn't leave this key silently listed in memory -- `keys`
            // is `@Observable`, so the list would otherwise update
            // immediately -- or orphaned in the Keychain, both while the
            // caller is being told generation/import failed.
            keys.removeLast()
            try? Keychain.delete(tag: key.keychainTag)
            throw error
        }
        return key
    }

    func delete(_ key: SSHKey) throws {
        // Metadata first, Keychain material last: if this instead deleted
        // Keychain material first and the metadata write below then
        // failed, `keys.json` would still list a key whose material is
        // already gone -- surfacing as a key that reappears (e.g. after
        // relaunch, since `keys` gets reloaded from that stale JSON) but
        // fails the moment it's actually used. Writing metadata first and
        // rolling it back on failure keeps key + material consistent;
        // deleting the material last leaves at worst an orphaned, inert
        // Keychain item if that final step itself fails, never a listed
        // key with missing material.
        let previousKeys = keys
        keys.removeAll { $0.id == key.id }
        do {
            try save()
        } catch {
            keys = previousKeys
            throw error
        }
        try Keychain.delete(tag: key.keychainTag)
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

    private func save() throws {
        try fileStore.save(keys)
    }
}
