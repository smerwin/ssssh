import Testing
import Foundation
@testable import ssssh

struct SSHKeyAlgorithmTests {
    @Test func displayNamesAreHumanReadable() {
        #expect(SSHKeyAlgorithm.ed25519.displayName == "Ed25519")
        #expect(SSHKeyAlgorithm.ecdsaP256.displayName == "ECDSA (P-256)")
        #expect(SSHKeyAlgorithm.ecdsaP384.displayName == "ECDSA (P-384)")
        #expect(SSHKeyAlgorithm.rsa.displayName == "RSA")
    }
}

struct SSHKeyTests {
    @Test func keychainTagIsStableAndScopedToTheKeyID() {
        let id = UUID()
        let key = SSHKey(
            id: id,
            label: "test",
            algorithm: .ed25519,
            createdAt: Date(),
            publicKeyOpenSSH: "ssh-ed25519 AAAA test",
            deployedHostIDs: []
        )
        #expect(key.keychainTag == "com.smerwin.ssssh.key.\(id.uuidString)")

        // Two keys must never collide on the same Keychain tag.
        let otherKey = SSHKey(
            id: UUID(),
            label: "other",
            algorithm: .ed25519,
            createdAt: Date(),
            publicKeyOpenSSH: "ssh-ed25519 AAAA other",
            deployedHostIDs: []
        )
        #expect(key.keychainTag != otherKey.keychainTag)
    }
}
