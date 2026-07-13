import SwiftUI

struct SettingsView: View {
    @AppStorage(AppSettingsKeys.terminalTheme) private var themeRawValue = TerminalTheme.crtGreen.rawValue
    @AppStorage(AppSettingsKeys.autoReconnect) private var autoReconnect = true

    var body: some View {
        NavigationStack {
            Form {
                Section("Terminal Theme") {
                    Picker("Theme", selection: $themeRawValue) {
                        Text("Green CRT").tag(TerminalTheme.crtGreen.rawValue)
                        Text("High Contrast").tag(TerminalTheme.highContrast.rawValue)
                    }
                    .pickerStyle(.inline)
                }
                Section {
                    Toggle("Auto-Reconnect", isOn: $autoReconnect)
                } footer: {
                    Text("When a session drops unexpectedly, automatically reconnect it. When off, dropped sessions are closed instead.")
                }
            }
            .navigationTitle("Settings")
        }
    }
}

#Preview {
    SettingsView()
}
