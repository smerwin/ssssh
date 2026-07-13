import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(KeyStore.self) private var keyStore
    @Environment(HostKeyStore.self) private var hostKeyStore
    @Environment(SessionManager.self) private var sessionManager

    var body: some View {
        TabView {
            HostListView()
                .tabItem { Label("Hosts", systemImage: "server.rack") }

            SessionsListView()
                .tabItem { Label("Sessions", systemImage: "rectangle.on.rectangle") }

            KeyListView()
                .tabItem { Label("Keys", systemImage: "key.fill") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                sessionManager.reconnectIfNeeded(keyStore: keyStore, hostKeyStore: hostKeyStore)
            }
        }
    }
}

#Preview {
    ContentView()
        .environment(HostStore())
        .environment(KeyStore())
        .environment(HostKeyStore())
        .environment(SessionManager())
}
