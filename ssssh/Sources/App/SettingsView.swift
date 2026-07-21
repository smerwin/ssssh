import SwiftUI

struct SettingsView: View {
    @Environment(PurchaseManager.self) private var purchaseManager
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @AppStorage(AppSettingsKeys.terminalTheme) private var themeRawValue = TerminalTheme.crtGreen.rawValue
    @AppStorage(AppSettingsKeys.autoReconnect) private var autoReconnect = true
    @AppStorage(AppSettingsKeys.verboseConnecting) private var verboseConnecting = true
    @AppStorage(AppSettingsKeys.autoUpgradeToMosh) private var autoUpgradeToMosh = false
    @AppStorage(AppSettingsKeys.autoUpgradeToET) private var autoUpgradeToET = false

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
                Section {
                    Picker(selection: $themeRawValue) {
                        ForEach(TerminalTheme.allCases, id: \.rawValue) { theme in
                            Text(theme.displayName)
                                .tag(theme.rawValue)
                                .disabled(colorSchemeContrast == .increased && theme != .highContrast)
                        }
                    } label: {
                        EmptyView()
                    }
                    .pickerStyle(.inline)
                } header: {
                    Text("Terminal Theme")
                } footer: {
                    if colorSchemeContrast == .increased {
                        Text("Increase Contrast is on in Accessibility settings, so the terminal always uses High Contrast. Turn it off in Settings > Accessibility > Display & Text Size to choose a different theme here.")
                    }
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
                Section {
                    Toggle("Auto-Upgrade to Mosh", isOn: $autoUpgradeToMosh)
                } footer: {
                    Text("When connecting, check whether the remote host has mosh-server installed, and if so, run the session over Mosh instead of plain SSH -- surviving network changes and dropped Wi-Fi without reconnecting. Each step is reported in the terminal when Verbose Connecting is also on. Falls back to plain SSH automatically if Mosh isn't available.")
                }
                Section {
                    Toggle("Auto-Upgrade to Eternal Terminal", isOn: $autoUpgradeToET)
                } footer: {
                    Text("When connecting, check whether the remote host has etserver running, and if so, run the session over Eternal Terminal instead of plain SSH -- reconnecting automatically after a dropped connection without losing the session. Each step is reported in the terminal when Verbose Connecting is also on. Falls back to plain SSH automatically if Eternal Terminal isn't available. Mutually exclusive with Auto-Upgrade to Mosh -- turning one on turns the other off, since a connection only ever attempts one upgrade path.")
                }
            }
            // Mutual exclusivity: each toggle turns the other off rather
            // than the two being allowed on together. SSHConnection itself
            // only ever races one upgrade path per connection (see
            // runSession's upgradeMode selection), so leaving both on would
            // silently mean "whichever one happens to be checked first" --
            // surfacing that ambiguity in the UI instead is clearer than
            // letting a user believe both are active.
            .onChange(of: autoUpgradeToMosh) { _, newValue in
                if newValue { autoUpgradeToET = false }
            }
            .onChange(of: autoUpgradeToET) { _, newValue in
                if newValue { autoUpgradeToMosh = false }
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
