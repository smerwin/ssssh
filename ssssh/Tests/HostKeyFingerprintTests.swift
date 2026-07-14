import Testing
import NIOSSH
@testable import ssssh

struct HostKeyFingerprintTests {
    @Test func sha256HasStandardOpenSSHShape() throws {
        let generated = KeyGenerator.generateEd25519(comment: "test")
        let publicKey = try NIOSSHPublicKey(openSSHPublicKey: generated.publicKeyOpenSSH)

        let fingerprint = HostKeyFingerprint.sha256(of: publicKey)

        #expect(fingerprint.hasPrefix("SHA256:"))
        // Base64's `=` padding is stripped, matching `ssh-keygen -lf`'s output.
        #expect(!fingerprint.contains("="))
    }

    @Test func sameKeyAlwaysProducesTheSameFingerprint() throws {
        let generated = KeyGenerator.generateEd25519(comment: "test")
        let publicKey = try NIOSSHPublicKey(openSSHPublicKey: generated.publicKeyOpenSSH)

        #expect(HostKeyFingerprint.sha256(of: publicKey) == HostKeyFingerprint.sha256(of: publicKey))
    }

    @Test func differentKeysProduceDifferentFingerprints() throws {
        let first = try NIOSSHPublicKey(openSSHPublicKey: KeyGenerator.generateEd25519(comment: "a").publicKeyOpenSSH)
        let second = try NIOSSHPublicKey(openSSHPublicKey: KeyGenerator.generateEd25519(comment: "b").publicKeyOpenSSH)

        #expect(HostKeyFingerprint.sha256(of: first) != HostKeyFingerprint.sha256(of: second))
    }
}
