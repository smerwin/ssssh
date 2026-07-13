import Foundation

/// `UserDefaults`/`@AppStorage` key names shared between `SettingsView`
/// (which reads/writes them via `@AppStorage`) and plain model code like
/// `SessionManager` (which reads them directly via `UserDefaults`, since
/// `@AppStorage` is a SwiftUI-only property wrapper).
enum AppSettingsKeys {
    static let terminalTheme = "terminalTheme"
    static let autoReconnect = "autoReconnect"
    static let verboseConnecting = "verboseConnecting"
}
