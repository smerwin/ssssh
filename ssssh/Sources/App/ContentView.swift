import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(SessionManager.self) private var sessionManager
    @AppStorage(AppSettingsKeys.terminalTheme) private var themeRawValue = TerminalTheme.crtGreen.rawValue

    private var theme: TerminalTheme {
        TerminalTheme(rawValue: themeRawValue) ?? .crtGreen
    }

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
        .tint(theme.accentColor)
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                sessionManager.reconnectIfNeeded()
            }
        }
    }
}

#Preview {
    let keyStore = KeyStore()
    let hostKeyStore = HostKeyStore()
    ContentView()
        .environment(HostStore())
        .environment(keyStore)
        .environment(hostKeyStore)
        .environment(SessionManager(keyStore: keyStore, hostKeyStore: hostKeyStore))
        .environment(PurchaseManager())
}
