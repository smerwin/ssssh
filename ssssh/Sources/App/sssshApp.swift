import SwiftUI

@main
struct sssshApp: App {
    @State private var hostStore = HostStore()
    @State private var keyStore = KeyStore()
    @State private var hostKeyStore = HostKeyStore()
    @State private var sessionManager = SessionManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(hostStore)
                .environment(keyStore)
                .environment(hostKeyStore)
                .environment(sessionManager)
                .sheet(item: Bindable(hostKeyStore).pendingConfirmation) { pending in
                    HostKeyConfirmationView(pending: pending)
                }
        }
    }
}
