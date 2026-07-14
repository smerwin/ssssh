import SwiftUI

/// The "tabs" view for milestone 4: every host with a live or recent
/// connection, so switching between concurrent sessions doesn't require
/// walking back through the Hosts list. Each row reuses the same
/// `SSHConnection` instance held by `SessionManager`.
struct SessionsListView: View {
    @Environment(SessionManager.self) private var sessionManager
    @Environment(TerminalViewStore.self) private var terminalViewStore

    var body: some View {
        NavigationStack {
            List {
                if sessionManager.sessions.isEmpty {
                    ContentUnavailableView(
                        "No Open Sessions",
                        systemImage: "rectangle.on.rectangle",
                        description: Text("Connect to a host from the Hosts tab.")
                    )
                }
                ForEach(sessionManager.sessions) { session in
                    NavigationLink(value: session) {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(displayName(for: session)).font(.headline)
                                Text(statusText(for: session.state))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            statusDot(for: session.state)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            sessionManager.close(session)
                            terminalViewStore.prune(activeIDs: Set(sessionManager.sessions.map(\.id)))
                        } label: {
                            Label("Close", systemImage: "xmark")
                        }
                    }
                }
            }
            .navigationTitle("Sessions")
            .navigationDestination(for: SSHConnection.self) { session in
                TerminalSessionView(connection: session)
            }
        }
        // Also catches sessions closed elsewhere (e.g. an unexpected drop
        // with auto-reconnect disabled) so that session's terminal view is
        // freed even when it wasn't closed through this list's swipe action.
        .onChange(of: sessionManager.sessions) { _, sessions in
            terminalViewStore.prune(activeIDs: Set(sessions.map(\.id)))
        }
    }

    /// Multiple concurrent sessions to the same host (see `HostListView`'s
    /// "New Session" action, used to rescue a session stuck on a hung
    /// connection) would otherwise be indistinguishable in this list, since
    /// they all share the same host and nickname. Numbers them by creation
    /// order only when there's more than one for that host.
    private func displayName(for session: SSHConnection) -> String {
        let sameHost = sessionManager.sessions.filter { $0.host.id == session.host.id }
        guard sameHost.count > 1, let index = sameHost.firstIndex(where: { $0.id == session.id }) else {
            return session.host.nickname
        }
        return "\(session.host.nickname) (\(index + 1))"
    }

    private func statusText(for state: SSHConnection.State) -> String {
        switch state {
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .disconnected: return "Disconnected"
        case .failed(let message): return message
        case .waitingToReconnect: return "Reconnecting…"
        }
    }

    private func statusDot(for state: SSHConnection.State) -> some View {
        let color: Color
        switch state {
        case .connected: color = .green
        case .connecting, .waitingToReconnect: color = .yellow
        case .disconnected, .failed: color = .red
        }
        return Circle().fill(color).frame(width: 8, height: 8)
            .accessibilityHidden(true)
    }
}
