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

    private let keyStore: KeyStore
    private let hostKeyStore: HostKeyStore

    init(keyStore: KeyStore, hostKeyStore: HostKeyStore) {
        self.keyStore = keyStore
        self.hostKeyStore = hostKeyStore
    }

    func session(for host: SSHHost) -> SSHConnection {
        if let existing = sessions.first(where: { $0.host.id == host.id }) {
            if existing.state.isDisconnectedOrFailed {
                existing.connect(keyStore: keyStore, hostKeyStore: hostKeyStore)
            }
            return existing
        }
        let connection = makeConnection(for: host)
        sessions.append(connection)
        connection.connect(keyStore: keyStore, hostKeyStore: hostKeyStore)
        return connection
    }

    func close(_ connection: SSHConnection) {
        sessions.removeAll { $0.id == connection.id }
        connection.disconnect()
    }

    /// Called when the app returns to the foreground; reconnects any
    /// session that dropped while backgrounded, regardless of the
    /// auto-reconnect setting -- the user bringing the app back to the
    /// foreground is itself an explicit signal they want back in.
    func reconnectIfNeeded() {
        for session in sessions where session.state.isDisconnectedOrFailed {
            session.connect(keyStore: keyStore, hostKeyStore: hostKeyStore)
        }
    }

    private func makeConnection(for host: SSHHost) -> SSHConnection {
        let connection = SSHConnection(host: host)
        connection.onDrop = { [weak self, weak connection] in
            guard let self, let connection else { return }
            if UserDefaults.standard.autoReconnectEnabled {
                connection.reconnectWithBackoff(keyStore: self.keyStore, hostKeyStore: self.hostKeyStore)
            } else {
                self.close(connection)
            }
        }
        return connection
    }
}

private extension UserDefaults {
    /// Defaults to `true` (matching the pre-toggle behavior of always
    /// reconnecting) when the user has never touched the setting.
    var autoReconnectEnabled: Bool {
        object(forKey: AppSettingsKeys.autoReconnect) == nil || bool(forKey: AppSettingsKeys.autoReconnect)
    }
}
