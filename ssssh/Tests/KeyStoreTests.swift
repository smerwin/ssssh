import Testing
import Foundation
@testable import ssssh

/// Deliberately never calls `generateKey`/`privateKeyMaterial` -- those
/// touch the Keychain's biometric-gated `load`, which has nothing to
/// authenticate against in a headless CI simulator. These tests only
/// exercise the metadata (JSON) persistence and bookkeeping logic, seeding
/// state directly via the JSON file `KeyStore` reads on init instead.
@MainActor
struct KeyStoreTests {
    private func write(_ keys: [SSHKey], to url: URL) throws {
        try JSONEncoder().encode(keys).write(to: url, options: .atomic)
    }

    private func makeKey(label: String = "test") -> SSHKey {
        SSHKey(
            id: UUID(),
            label: label,
            algorithm: .ed25519,
            createdAt: Date(),
            publicKeyOpenSSH: "ssh-ed25519 AAAA \(label)",
            deployedHostIDs: []
        )
    }

    @Test func loadsExistingMetadataOnInit() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let seeded = makeKey()
        try write([seeded], to: tempURL)

        let store = KeyStore(metadataURL: tempURL)
        #expect(store.keys == [seeded])
    }

    @Test func markDeployedIsIdempotentAndPersists() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let key = makeKey()
        try write([key], to: tempURL)
        let hostID = UUID()

        let store = KeyStore(metadataURL: tempURL)
        try store.markDeployed(key, to: hostID)
        #expect(store.keys.first?.deployedHostIDs == [hostID])

        // Marking the same host again must not duplicate the entry.
        try store.markDeployed(key, to: hostID)
        #expect(store.keys.first?.deployedHostIDs == [hostID])

        // Persisted to disk, not just in memory.
        let reloaded = KeyStore(metadataURL: tempURL)
        #expect(reloaded.keys.first?.deployedHostIDs == [hostID])
    }

    @Test func deleteRemovesFromListAndPersists() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let key = makeKey()
        try write([key], to: tempURL)

        let store = KeyStore(metadataURL: tempURL)
        // `Keychain.delete` tolerates a missing item (no key was ever
        // actually saved to the Keychain here), so this is safe without
        // a prior `generateKey` call.
        try store.delete(key)

        #expect(store.keys.isEmpty)
        let reloaded = KeyStore(metadataURL: tempURL)
        #expect(reloaded.keys.isEmpty)
    }
}
