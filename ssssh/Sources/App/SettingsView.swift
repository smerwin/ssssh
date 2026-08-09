import SwiftUI

struct SettingsView: View {
    @Environment(PurchaseManager.self) private var purchaseManager
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage(AppSettingsKeys.terminalTheme) private var themeRawValue = TerminalTheme.crtGreen.rawValue
    @AppStorage(AppSettingsKeys.terminalFontSize) private var terminalFontSize = TerminalFontSize.standard
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
                    // Rendered in exactly the font the terminal itself will
                    // use -- same base size, same Dynamic Type scaling, same
                    // theme colors -- so the slider's effect is visible
                    // without leaving Settings to go find a session.
                    Text(Self.sampleTerminalLine)
                        .font(.system(size: CGFloat(previewFontSize), design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(previewTheme.foreground)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(previewTheme.background, in: RoundedRectangle(cornerRadius: 6))
                        .accessibilityHidden(true)
                    Slider(
                        value: $terminalFontSize,
                        in: TerminalFontSize.minimum...TerminalFontSize.maximum,
                        step: TerminalFontSize.step
                    ) {
                        Text("Text Size")
                    } minimumValueLabel: {
                        Text("A").font(.footnote)
                    } maximumValueLabel: {
                        Text("A").font(.title2)
                    }
                    // Without this VoiceOver announces a bare number ("18")
                    // for a value whose whole meaning is its unit.
                    .accessibilityValue(TerminalFontSize.description(of: terminalFontSize))
                    LabeledContent("Size", value: TerminalFontSize.description(of: terminalFontSize))
                    Button("Reset to Default") {
                        terminalFontSize = TerminalFontSize.standard
                    }
                    .disabled(terminalFontSize == TerminalFontSize.standard)
                } header: {
                    Text("Terminal Text Size")
                } footer: {
                    Text("Pinch to zoom in the terminal to change this from there too -- it's the same setting either way. Text also scales with the system text size from Settings > Accessibility > Display & Text Size, so this moves up or down from whatever that's set to.")
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

    /// Short enough to stay on one line at the largest supported size on a
    /// phone, and recognizably a shell prompt rather than lorem ipsum.
    private static let sampleTerminalLine = "user@host:~$ ls -la"

    private var previewTheme: TerminalTheme {
        TerminalTheme.resolved(rawValue: themeRawValue, increasedContrast: colorSchemeContrast == .increased)
    }

    /// The size the terminal will actually render at: the slider's base size
    /// with Dynamic Type applied, exactly as `TerminalSessionController` does
    /// it. `Font.system(size:)` is a fixed size that SwiftUI won't scale on
    /// its own, so applying the scaling here doesn't double up.
    private var previewFontSize: Double {
        TerminalFontSize.scaledSize(baseSize: terminalFontSize, contentSizeCategory: dynamicTypeSize.uiContentSizeCategory)
    }
}

#Preview {
    SettingsView()
        .environment(PurchaseManager())
}
