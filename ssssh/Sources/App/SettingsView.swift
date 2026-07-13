import SwiftUI

struct SettingsView: View {
    @Environment(PurchaseManager.self) private var purchaseManager
    @AppStorage(AppSettingsKeys.terminalTheme) private var themeRawValue = TerminalTheme.crtGreen.rawValue
    @AppStorage(AppSettingsKeys.autoReconnect) private var autoReconnect = true
    @AppStorage(AppSettingsKeys.verboseConnecting) private var verboseConnecting = true

    @State private var isPresentingPaywall = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if purchaseManager.isUnlocked {
                        Label("Unlimited Hosts & Keys Unlocked", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button {
                            isPresentingPaywall = true
                        } label: {
                            Label("Unlock Unlimited Hosts & Keys", systemImage: "infinity.circle")
                        }
                        Button("Restore Purchases") {
                            Task { await purchaseManager.restorePurchases() }
                        }
                    }
                }
                Section("Terminal Theme") {
                    Picker(selection: $themeRawValue) {
                        ForEach(TerminalTheme.allCases, id: \.rawValue) { theme in
                            Text(theme.displayName).tag(theme.rawValue)
                        }
                    } label: {
                        EmptyView()
                    }
                    .pickerStyle(.inline)
                }
                Section {
                    Toggle("Auto-Reconnect", isOn: $autoReconnect)
                } footer: {
                    Text("When a session drops unexpectedly, automatically reconnect it. When off, dropped sessions are closed instead.")
                }
                Section {
                    Toggle("Verbose Connecting", isOn: $verboseConnecting)
                } footer: {
                    Text("Show ssh -v-style connection details (connecting, authenticating, requesting a pty) in the terminal while a session connects.")
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $isPresentingPaywall) {
                PaywallView()
            }
        }
    }
}

#Preview {
    SettingsView()
        .environment(PurchaseManager())
}
