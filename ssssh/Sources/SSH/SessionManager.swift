import Foundation
import Observation

/// Keeps SSH connections alive independent of which view is on screen, so a
/// terminal session survives navigation and backgrounding. One connection
/// per host is kept; reopening a host's session reuses the existing
/// connection instead of reconnecting.
@MainActor
@Observable
final class SessionManager {
    private(set) var sessions: [SSHConnection] = []

    func session(for host: SSHHost, keyStore: KeyStore, hostKeyStore: HostKeyStore) -> SSHConnection {
        if let existing = sessions.first(where: { $0.host.id == host.id }) {
            return existing
        }
        let connection = SSHConnection(host: host)
        sessions.append(connection)
        connection.connect(keyStore: keyStore, hostKeyStore: hostKeyStore)
        return connection
    }

    func close(_ connection: SSHConnection) {
        sessions.removeAll { $0.id == connection.id }
        connection.disconnect()
    }

    /// Called when the app returns to the foreground; reconnects any
    /// session that dropped while backgrounded.
    func reconnectIfNeeded(keyStore: KeyStore, hostKeyStore: HostKeyStore) {
        for session in sessions where session.state.isDisconnectedOrFailed {
            session.connect(keyStore: keyStore, hostKeyStore: hostKeyStore)
        }
    }
}
