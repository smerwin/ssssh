import SwiftUI

struct SettingsView: View {
    @AppStorage("terminalTheme") private var themeRawValue = TerminalTheme.crtGreen.rawValue

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
            }
            .navigationTitle("Settings")
        }
    }
}

#Preview {
    SettingsView()
}
