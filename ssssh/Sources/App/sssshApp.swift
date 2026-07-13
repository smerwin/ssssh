import SwiftUI

@main
struct sssshApp: App {
    @State private var hostStore = HostStore()
    @State private var keyStore = KeyStore()
    @State private var hostKeyStore = HostKeyStore()
    @State private var sessionManager: SessionManager
    @State private var purchaseManager = PurchaseManager()

    init() {
        let keyStore = KeyStore()
        let hostKeyStore = HostKeyStore()
        _keyStore = State(initialValue: keyStore)
        _hostKeyStore = State(initialValue: hostKeyStore)
        _sessionManager = State(initialValue: SessionManager(keyStore: keyStore, hostKeyStore: hostKeyStore))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(hostStore)
                .environment(keyStore)
                .environment(hostKeyStore)
                .environment(sessionManager)
                .environment(purchaseManager)
                .sheet(item: Bindable(hostKeyStore).pendingConfirmation) { pending in
                    HostKeyConfirmationView(pending: pending)
                }
        }
    }
}
