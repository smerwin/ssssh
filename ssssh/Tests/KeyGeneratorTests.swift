import Testing
import NIOSSH
@testable import ssssh

struct KeyGeneratorTests {
    @Test func ed25519PublicKeyLineHasExpectedShape() {
        let generated = KeyGenerator.generateEd25519(comment: "test")
        #expect(generated.algorithm == .ed25519)
        #expect(generated.publicKeyOpenSSH.hasPrefix("ssh-ed25519 "))
        #expect(generated.publicKeyOpenSSH.hasSuffix(" test"))
    }

    @Test func ecdsaP256PublicKeyLineHasExpectedShape() {
        let generated = KeyGenerator.generateECDSAP256(comment: "test")
        #expect(generated.algorithm == .ecdsaP256)
        #expect(generated.publicKeyOpenSSH.hasPrefix("ecdsa-sha2-nistp256 "))
        #expect(generated.publicKeyOpenSSH.hasSuffix(" test"))
    }

    @Test func ecdsaP384PublicKeyLineHasExpectedShape() {
        let generated = KeyGenerator.generateECDSAP384(comment: "test")
        #expect(generated.algorithm == .ecdsaP384)
        #expect(generated.publicKeyOpenSSH.hasPrefix("ecdsa-sha2-nistp384 "))
        #expect(generated.publicKeyOpenSSH.hasSuffix(" test"))
    }

    // `generate(algorithm:comment:)` is the dispatcher every real call site
    // (`KeyStore.generateKey`) actually goes through -- covers that it
    // routes to the right generator rather than just testing the
    // per-algorithm functions directly.
    @Test func generateDispatchesToTheRequestedAlgorithm() {
        for algorithm: SSHKeyAlgorithm in [.ed25519, .ecdsaP256, .ecdsaP384] {
            let generated = KeyGenerator.generate(algorithm: algorithm, comment: "test")
            #expect(generated.algorithm == algorithm)
        }
    }

    /// Every generated public key line must be valid, parseable OpenSSH
    /// wire format -- the exact thing a real server's `authorized_keys`
    /// and NIOSSH's own parser need to accept it.
    @Test func generatedPublicKeysParseAsValidOpenSSHKeys() throws {
        for algorithm: SSHKeyAlgorithm in [.ed25519, .ecdsaP256, .ecdsaP384] {
            let generated = KeyGenerator.generate(algorithm: algorithm, comment: "test")
            // Throws (failing the test) if the line isn't valid OpenSSH
            // wire format.
            _ = try NIOSSHPublicKey(openSSHPublicKey: generated.publicKeyOpenSSH)
        }
    }
}
