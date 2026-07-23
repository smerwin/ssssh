import AppIntents

struct sssshShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RunCommandIntent(),
            // A phrase can only reference a single parameter, and only an
            // `AppEntity`/`AppEnum`-typed one at that (both confirmed by
            // the `appintentsmetadataprocessor` build step, which halts
            // on "Multiple parameters detected in phrase" and "Invalid
            // parameter type" respectively) -- `command` is a plain
            // `String`, so only `host` can appear in a phrase.
            phrases: [
                "Run a command on \(\.$host) in \(.applicationName)",
                "Run a command in \(.applicationName)"
            ],
            shortTitle: "Run Command",
            systemImageName: "terminal"
        )
    }
}
