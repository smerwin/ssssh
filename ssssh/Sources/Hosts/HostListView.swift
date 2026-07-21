import SwiftUI

struct HostListView: View {
    @Environment(HostStore.self) private var hostStore
    @Environment(HostKeyStore.self) private var hostKeyStore
    @Environment(SessionManager.self) private var sessionManager
    @Environment(PurchaseManager.self) private var purchaseManager

    @State private var isPresentingAddHost = false
    @State private var isPresentingPaywall = false
    @State private var editingHost: SSHHost?
    @State private var copyKeyHost: SSHHost?
    @State private var hostPendingDeletion: SSHHost?
    @State private var deleteErrorMessage: String?
    @State private var hostPendingForgetKey: SSHHost?
    @State private var pendingNewSession: SSHConnection?
    @State private var activeSession: SSHConnection?

    var body: some View {
        NavigationStack {
            List {
                if hostStore.hosts.isEmpty {
                    ContentUnavailableView {
                        Label("No Hosts Yet", systemImage: "server.rack")
                    } description: {
                        Text("Add a host to connect to. If you haven't generated a key yet, visit the Keys tab first.")
                    } actions: {
                        Button("Add Host") { isPresentingAddHost = true }
                    }
                }
                ForEach(hostStore.hosts) { host in
                    // Not a `NavigationLink(value: host)` -- that would need
                    // `navigationDestination(for: SSHHost.self)` to resolve
                    // `sessionManager.session(for: host)` inside its
                    // closure, and that closure re-runs on every re-render
                    // Observation triggers for anything it read, not only
                    // on an actual tap. Since `session(for:)` can create and
                    // connect a brand-new session as a side effect, that
                    // silently reconnected a host whose session had just
                    // been closed elsewhere (e.g. swiping it away in the
                    // Sessions tab), because this tab's own pushed
                    // destination for the same host was still re-evaluating
                    // in the background. Resolving the session once, here,
                    // only in direct response to a tap, keeps that lookup
                    // out of the render path entirely.
                    Button {
                        activeSession = sessionManager.session(for: host)
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(host.nickname).font(.headline)
                                Text("\(host.username)@\(host.hostname):\(host.port)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            hostPendingDeletion = host
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button {
                            editingHost = host
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
                    .contextMenu {
                        // Unlike tapping the row (which reuses the host's
                        // existing session via `session(for:)`), this always
                        // opens a second, independent connection -- the way
                        // to rescue a session that's stuck on a hung
                        // connection without tearing the original down.
                        Button {
                            pendingNewSession = sessionManager.newSession(for: host)
                        } label: {
                            Label("New Session", systemImage: "plus.rectangle.on.rectangle")
                        }
                        Button {
                            copyKeyHost = host
                        } label: {
                            Label("Copy Key to Server", systemImage: "key")
                        }
                        Button {
                            editingHost = host
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        if hostKeyStore.fingerprint(for: host.id) != nil {
                            Button(role: .destructive) {
                                hostPendingForgetKey = host
                            } label: {
                                Label("Forget Known Host Key", systemImage: "exclamationmark.triangle")
                            }
                        }
                        Button(role: .destructive) {
                            hostPendingDeletion = host
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle("Hosts")
            .navigationDestination(item: $activeSession) { session in
                TerminalSessionView(connection: session)
            }
            .navigationDestination(item: $pendingNewSession) { session in
                TerminalSessionView(connection: session)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        if purchaseManager.isUnlocked || hostStore.hosts.isEmpty {
                            isPresentingAddHost = true
                        } else {
                            isPresentingPaywall = true
                        }
                    } label: {
                        Label("New Host", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $isPresentingAddHost) {
                HostEditView()
            }
            .sheet(item: $editingHost) { host in
                HostEditView(existingHost: host)
            }
            .sheet(item: $copyKeyHost) { host in
                CopyKeyToServerView(host: host)
            }
            .sheet(isPresented: $isPresentingPaywall) {
                PaywallView()
            }
            .destructiveConfirmationAlert("Delete Host", item: $hostPendingDeletion) { host in
                Text("\"\(host.nickname)\" will be removed from ssssh. You can add it again later.")
            } onConfirm: { host in
                do {
                    try hostStore.delete(host)
                } catch {
                    // Previously `try?`, which silently swallowed a disk
                    // failure -- the confirmation alert dismissed as if the
                    // delete succeeded, with the host quietly still present.
                    deleteErrorMessage = error.localizedDescription
                }
            }
            .alert(
                "Couldn't Delete Host",
                isPresented: Binding(
                    get: { deleteErrorMessage != nil },
                    set: { if !$0 { deleteErrorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(deleteErrorMessage ?? "")
            }
            .destructiveConfirmationAlert(
                "Forget Known Host Key",
                item: $hostPendingForgetKey,
                confirmTitle: "Forget Known Host Key"
            ) { host in
                Text("The next connection to \"\(host.nickname)\" will trust whatever host key the server presents, with no warning if it has changed since you last connected. Only do this if you know the server was legitimately reinstalled or had its key rotated.")
            } onConfirm: { host in
                hostKeyStore.forget(hostID: host.id)
            }
        }
    }
}

#Preview {
    let keyStore = KeyStore()
    let hostKeyStore = HostKeyStore()
    HostListView()
        .environment(HostStore())
        .environment(keyStore)
        .environment(hostKeyStore)
        .environment(SessionManager(keyStore: keyStore, hostKeyStore: hostKeyStore))
        .environment(PurchaseManager())
}
