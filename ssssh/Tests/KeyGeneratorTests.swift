import Testing
@testable import ssssh

struct KeyGeneratorTests {
    @Test func ed25519PublicKeyLineHasExpectedShape() {
        let generated = KeyGenerator.generateEd25519(comment: "test")
        #expect(generated.algorithm == .ed25519)
        #expect(generated.publicKeyOpenSSH.hasPrefix("ssh-ed25519 "))
        #expect(generated.publicKeyOpenSSH.hasSuffix(" test"))
    }
}
