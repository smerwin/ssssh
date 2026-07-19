import Foundation
import Observation
import UIKit

/// Keeps SSH connections alive independent of which view is on screen, so a
/// terminal session survives navigation and backgrounding. `session(for:)`
/// keeps one *primary* connection per host and reuses it on repeat opens;
/// `newSession(for:)` always opens an additional, independent connection to
/// the same host, regardless of any existing one's state -- e.g. to rescue
/// a session that's stuck on a hung connection without having to tear the
/// original down first.
@MainActor
@Observable
final class SessionManager {
    private(set) var sessions: [SSHConnection] = []

    private let keyStore: KeyStore
    private let hostKeyStore: HostKeyStore

    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var backgroundKeepAliveTask: Task<Void, Never>?

    /// How often to nudge each connected session with a harmless keepalive
    /// while backgrounded.
    private static let keepAliveInterval: Duration = .seconds(20)
    /// Upper bound on how long the background keepalive runs for, regardless
    /// of how much execution time iOS actually grants the background task --
    /// this is what makes an active connection survive the phone sleeping
    /// for up to five minutes, not indefinitely.
    private static let maxBackgroundDuration: Duration = .seconds(5 * 60)

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
        return newSession(for: host)
    }

    @discardableResult
    func newSession(for host: SSHHost) -> SSHConnection {
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

    /// Called when the app moves to the background -- including the phone
    /// simply going to sleep with this app on screen, which backgrounds it
    /// the same way switching apps does. Requests extra execution time from
    /// iOS and spends it nudging each connected session with a harmless
    /// keepalive, so an active connection has a chance to survive up to
    /// five minutes of backgrounding instead of going stale the moment the
    /// screen locks.
    func applicationDidEnterBackground() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "ssh-keepalive") { [weak self] in
            self?.endBackgroundKeepAlive()
        }
        guard backgroundTaskID != .invalid else { return }

        backgroundKeepAliveTask = Task { [weak self] in
            let deadline = ContinuousClock.now.advanced(by: Self.maxBackgroundDuration)
            while ContinuousClock.now < deadline {
                try? await Task.sleep(for: Self.keepAliveInterval)
                guard !Task.isCancelled else { return }
                guard let self else { return }
                for session in self.sessions where session.state == .connected {
                    session.sendKeepalive()
                }
            }
            self?.endBackgroundKeepAlive()
        }
    }

    /// Called when the app returns to the foreground. Ends any in-flight
    /// background keepalive before `reconnectIfNeeded()` handles anything
    /// that still dropped anyway.
    func applicationWillEnterForeground() {
        endBackgroundKeepAlive()
        reconnectIfNeeded()
    }

    private func endBackgroundKeepAlive() {
        backgroundKeepAliveTask?.cancel()
        backgroundKeepAliveTask = nil
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
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
