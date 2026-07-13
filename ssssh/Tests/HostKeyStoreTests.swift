import Testing
import Foundation
@testable import ssssh

@MainActor
struct HostKeyStoreTests {
    @Test func alreadyTrustedHostDoesNotPromptAgain() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let store = HostKeyStore(storageURL: tempURL)
        let host = SSHHost(nickname: "test", hostname: "example.com", username: "me")

        // First connection to a new host: evaluate must suspend on a
        // pending confirmation rather than resolving immediately.
        let firstConnect = Task { try await store.evaluate(host: host, fingerprint: "SHA256:abc") }
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.pendingConfirmation != nil)
        store.pendingConfirmation?.decide(true)
        try await firstConnect.value
        #expect(store.fingerprint(for: host.id) == "SHA256:abc")

        // Second connection with the SAME fingerprint: must return
        // immediately with no confirmation prompt. This is the exact
        // regression that shipped previously -- the early `return` was
        // written inside a `MainActor.run { ... }` closure, which only
        // exits that closure, not `evaluate` itself, so execution always
        // fell through to the confirmation-dialog path even for a host
        // that was already trusted.
        try await store.evaluate(host: host, fingerprint: "SHA256:abc")
        #expect(store.pendingConfirmation == nil)

        // Third connection with a DIFFERENT fingerprint: must throw
        // HostKeyMismatch, not silently trust or re-prompt.
        await #expect(throws: HostKeyMismatch.self) {
            try await store.evaluate(host: host, fingerprint: "SHA256:xyz")
        }
    }
}
