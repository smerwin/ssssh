import Testing
import Foundation
@testable import ssssh

struct RunCommandPreflightTests {
    private func makeHost(keyID: UUID? = nil) -> SSHHost {
        SSHHost(nickname: "box", hostname: "1.2.3.4", username: "root", keyID: keyID)
    }

    @Test func failsWhenTheHostHasNoKeyConfigured() {
        let host = makeHost()
        #expect(throws: RunCommandPreflightError.self) {
            try RunCommandPreflight.validate(host: host, trustedFingerprint: "SHA256:abc")
        }
    }

    @Test func failsWhenTheHostKeyIsNotYetTrusted() {
        let host = makeHost(keyID: UUID())
        #expect(throws: RunCommandPreflightError.self) {
            try RunCommandPreflight.validate(host: host, trustedFingerprint: nil)
        }
    }

    @Test func succeedsAndReturnsTheKeyIDWhenBothConditionsAreMet() throws {
        let keyID = UUID()
        let host = makeHost(keyID: keyID)
        #expect(try RunCommandPreflight.validate(host: host, trustedFingerprint: "SHA256:abc") == keyID)
    }
}
