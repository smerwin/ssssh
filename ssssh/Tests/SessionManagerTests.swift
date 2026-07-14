import Testing
import Foundation
@testable import ssssh

@MainActor
struct SessionManagerTests {
    @Test func sessionReusesExistingConnectionForSameHost() throws {
        let manager = SessionManager(keyStore: KeyStore(), hostKeyStore: HostKeyStore())
        let host = SSHHost(nickname: "test", hostname: "example.com", username: "me")

        let first = manager.session(for: host)
        let second = manager.session(for: host)

        #expect(first === second)
        #expect(manager.sessions.count == 1)
    }

    @Test func newSessionAlwaysOpensAnAdditionalConnectionToTheSameHost() throws {
        // Covers the "rescue a stuck session" path: `newSession(for:)` must
        // never reuse an existing connection the way `session(for:)` does,
        // even when one already exists for this host.
        let manager = SessionManager(keyStore: KeyStore(), hostKeyStore: HostKeyStore())
        let host = SSHHost(nickname: "test", hostname: "example.com", username: "me")

        let original = manager.session(for: host)
        let rescue = manager.newSession(for: host)

        #expect(original !== rescue)
        #expect(manager.sessions.count == 2)
        #expect(manager.sessions.allSatisfy { $0.host.id == host.id })

        // Closing one independent session must leave the other untouched.
        manager.close(original)
        #expect(manager.sessions == [rescue])
    }
}
