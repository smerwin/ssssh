import SwiftUI

/// The "tabs" view for milestone 4: every host with a live or recent
/// connection, so switching between concurrent sessions doesn't require
/// walking back through the Hosts list. Each row reuses the same
/// `SSHConnection` instance held by `SessionManager`.
struct SessionsListView: View {
    @Environment(SessionManager.self) private var sessionManager

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
                                Text(session.host.nickname).font(.headline)
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
    }

    private func statusText(for state: SSHConnection.State) -> String {
        switch state {
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .disconnected: return "Disconnected"
        case .failed(let message): return message
        }
    }

    private func statusDot(for state: SSHConnection.State) -> some View {
        let color: Color
        switch state {
        case .connected: color = .green
        case .connecting: color = .yellow
        case .disconnected, .failed: color = .red
        }
        return Circle().fill(color).frame(width: 8, height: 8)
    }
}
