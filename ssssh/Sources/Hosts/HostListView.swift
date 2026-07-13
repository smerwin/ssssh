import SwiftUI

struct HostListView: View {
    @State private var hostStore = HostStore()

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
                }
            }
            .navigationTitle("Hosts")
            .navigationDestination(for: SSHHost.self) { host in
                TerminalSessionView(host: host)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        // TODO: present add-host sheet (milestone 4)
                    } label: {
                        Label("New Host", systemImage: "plus")
                    }
                }
            }
        }
    }
}

#Preview {
    HostListView()
}
