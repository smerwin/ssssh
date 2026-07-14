import Testing
import Foundation
import CryptoKit
@testable import ssssh

struct SSHPrivateKeyMaterialTests {
    @Test func ed25519RoundTripsThroughRawRepresentation() throws {
        let original = Curve25519.Signing.PrivateKey()
        let material = try SSHPrivateKeyMaterial(algorithm: .ed25519, rawRepresentation: original.rawRepresentation)
        guard case .ed25519(let key) = material else {
            Issue.record("expected .ed25519, got \(material)")
            return
        }
        #expect(key.rawRepresentation == original.rawRepresentation)
    }

    @Test func ecdsaP256RoundTripsThroughRawRepresentation() throws {
        let original = P256.Signing.PrivateKey()
        let material = try SSHPrivateKeyMaterial(algorithm: .ecdsaP256, rawRepresentation: original.rawRepresentation)
        guard case .ecdsaP256(let key) = material else {
            Issue.record("expected .ecdsaP256, got \(material)")
            return
        }
        #expect(key.rawRepresentation == original.rawRepresentation)
    }

    @Test func ecdsaP384RoundTripsThroughRawRepresentation() throws {
        let original = P384.Signing.PrivateKey()
        let material = try SSHPrivateKeyMaterial(algorithm: .ecdsaP384, rawRepresentation: original.rawRepresentation)
        guard case .ecdsaP384(let key) = material else {
            Issue.record("expected .ecdsaP384, got \(material)")
            return
        }
        #expect(key.rawRepresentation == original.rawRepresentation)
    }

    @Test func rsaIsUnsupportedSinceThereIsNoImportUIYet() {
        #expect(throws: CocoaError.self) {
            try SSHPrivateKeyMaterial(algorithm: .rsa, rawRepresentation: Data())
        }
    }
}
