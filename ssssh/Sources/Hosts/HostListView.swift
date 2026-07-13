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

    var body: some View {
        NavigationStack {
            List {
                if hostStore.hosts.isEmpty {
                    ContentUnavailableView(
                        "No Hosts Yet",
                        systemImage: "server.rack",
                        description: Text("Add a host to connect to.")
                    )
                }
                ForEach(hostStore.hosts) { host in
                    NavigationLink(value: host) {
                        VStack(alignment: .leading) {
                            Text(host.nickname).font(.headline)
                            Text("\(host.username)@\(host.hostname):\(host.port)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            try? hostStore.delete(host)
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
                                hostKeyStore.forget(hostID: host.id)
                            } label: {
                                Label("Forget Known Host Key", systemImage: "exclamationmark.triangle")
                            }
                        }
                        Button(role: .destructive) {
                            try? hostStore.delete(host)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle("Hosts")
            .navigationDestination(for: SSHHost.self) { host in
                TerminalSessionView(connection: sessionManager.session(for: host))
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
