import SwiftUI

struct SettingsView: View {
    @AppStorage("terminalTheme") private var themeRawValue = TerminalTheme.crtGreen.rawValue

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
            }
            .navigationTitle("Settings")
        }
    }
}

#Preview {
    SettingsView()
}
