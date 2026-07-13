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
        guard algorithm == .ed25519 else {
            fatalError("Only Ed25519 generation is implemented in this scaffold")
        }
        let generated = KeyGenerator.generateEd25519(comment: label)
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
