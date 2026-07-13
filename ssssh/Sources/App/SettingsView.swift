import SwiftUI

struct SettingsView: View {
    @AppStorage(AppSettingsKeys.terminalTheme) private var themeRawValue = TerminalTheme.crtGreen.rawValue
    @AppStorage(AppSettingsKeys.autoReconnect) private var autoReconnect = true
    @AppStorage(AppSettingsKeys.verboseConnecting) private var verboseConnecting = true

    var body: some View {
        NavigationStack {
            Form {
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
        }
    }
}

#Preview {
    SettingsView()
}
