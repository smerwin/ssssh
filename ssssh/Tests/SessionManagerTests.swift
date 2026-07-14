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

    @Test func closeRemovesOnlyTheTargetedSessionAmongSeveral() throws {
        let manager = SessionManager(keyStore: KeyStore(), hostKeyStore: HostKeyStore())
        let hostA = SSHHost(nickname: "a", hostname: "a.example.com", username: "me")
        let hostB = SSHHost(nickname: "b", hostname: "b.example.com", username: "me")

        let first = manager.session(for: hostA)
        let second = manager.newSession(for: hostA)
        let third = manager.session(for: hostB)

        manager.close(second)

        #expect(manager.sessions.count == 2)
        #expect(manager.sessions.contains(first))
        #expect(manager.sessions.contains(third))
        #expect(!manager.sessions.contains(second))
    }

    @Test func reconnectIfNeededReconnectsInPlaceWithoutReplacingTheSession() throws {
        // A host with no configured key fails `connect()` synchronously
        // and deterministically (no real network involved), landing in
        // `.failed` -- exactly the state `reconnectIfNeeded` should act on.
        let manager = SessionManager(keyStore: KeyStore(), hostKeyStore: HostKeyStore())
        let host = SSHHost(nickname: "test", hostname: "example.com", username: "me")

        let session = manager.session(for: host)
        #expect(session.state.isDisconnectedOrFailed)

        manager.reconnectIfNeeded()

        // Same instance, still tracked, still (deterministically) failed --
        // proves reconnectIfNeeded calls connect() on the existing
        // connection rather than creating a replacement.
        #expect(manager.sessions == [session])
        #expect(session.state.isDisconnectedOrFailed)
    }
}
