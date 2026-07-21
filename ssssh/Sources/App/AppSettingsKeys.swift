import Foundation

/// `UserDefaults`/`@AppStorage` key names shared between `SettingsView`
/// (which reads/writes them via `@AppStorage`) and plain model code like
/// `SessionManager` (which reads them directly via `UserDefaults`, since
/// `@AppStorage` is a SwiftUI-only property wrapper).
enum AppSettingsKeys {
    static let terminalTheme = "terminalTheme"
    static let autoReconnect = "autoReconnect"
    static let verboseConnecting = "verboseConnecting"
    static let autoUpgradeToMosh = "autoUpgradeToMosh"
    static let autoUpgradeToET = "autoUpgradeToET"
}

extension UserDefaults {
    /// Returns the bool stored at `key`, or `true` if the user has never
    /// touched the setting -- for settings that default to "on".
    func boolDefaultingTrue(forKey key: String) -> Bool {
        object(forKey: key) == nil || bool(forKey: key)
    }

    /// Defaults to `true` (matching the pre-toggle behavior of always
    /// reconnecting) when the user has never touched the setting.
    var autoReconnectEnabled: Bool {
        boolDefaultingTrue(forKey: AppSettingsKeys.autoReconnect)
    }

    /// Defaults to `true` (verbose by default, matching `ssh -v`-style
    /// connecting output) when the user has never touched the setting.
    var verboseConnectingEnabled: Bool {
        boolDefaultingTrue(forKey: AppSettingsKeys.verboseConnecting)
    }

    /// Defaults to `false`: unlike Auto-Reconnect and Verbose Connecting,
    /// this opts into extra work on every connect (bootstrapping
    /// `mosh-server` and racing a real Mosh UDP session against the plain
    /// SSH PTY -- see `SSHConnection.attemptMoshUpgrade`), so it stays
    /// opt-in rather than on by default.
    var autoUpgradeToMoshEnabled: Bool {
        bool(forKey: AppSettingsKeys.autoUpgradeToMosh)
    }

    /// Same "opt-in, off by default" reasoning as `autoUpgradeToMoshEnabled`
    /// -- bootstraps `etterminal` over SSH and races a real Eternal
    /// Terminal TCP session against the plain SSH PTY (see
    /// `SSHConnection.attemptETUpgrade`). Mutually exclusive with Mosh in
    /// `SettingsView` (checking one unchecks the other) -- `SSHConnection`
    /// itself only ever reads this alongside `autoUpgradeToMoshEnabled` to
    /// pick at most one upgrade path per connection, never both, so this
    /// accessor doesn't need to re-enforce that exclusivity itself.
    var autoUpgradeToETEnabled: Bool {
        bool(forKey: AppSettingsKeys.autoUpgradeToET)
    }
}
