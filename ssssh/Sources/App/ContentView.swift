import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(SessionManager.self) private var sessionManager
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @AppStorage(AppSettingsKeys.terminalTheme) private var themeRawValue = TerminalTheme.crtGreen.rawValue

    /// Mirrors `TerminalSessionView`'s theme-resolution logic so the tab
    /// bar's tint stays consistent with the terminal when iOS's own
    /// Increase Contrast setting overrides the user's manual theme choice.
    private var theme: TerminalTheme {
        let stored = TerminalTheme(rawValue: themeRawValue) ?? .crtGreen
        return colorSchemeContrast == .increased ? .highContrast : stored
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
        .environment(TerminalViewStore())
        .environment(PurchaseManager())
}
