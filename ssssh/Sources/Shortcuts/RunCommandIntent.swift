import AppIntents

struct RunCommandIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Command"
    static let description = IntentDescription("Runs a command over SSH on a saved host and returns its output.")

    /// Deliberately `false`: this is the "runs silently from an automation"
    /// use case that makes Run Command worth having at all. Whether
    /// Keychain/Face ID access actually surfaces correctly with this set to
    /// `false`, when the app isn't already foregrounded, is UNVERIFIED --
    /// see CLAUDE.md's Apple Shortcuts section. `Keychain.load` fails fast
    /// with `KeychainError.interactionNotAllowed` rather than hanging if the
    /// OS can't show the prompt here, so the failure mode is at least
    /// legible either way.
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Host")
    var host: SSHHostEntity

    @Parameter(title: "Command")
    var command: String

    static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$command) on \(\.$host)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let sshHost = host.host

        let hostKeyStore = HostKeyStore()
        let keyID = try RunCommandPreflight.validate(
            host: sshHost,
            trustedFingerprint: hostKeyStore.fingerprint(for: sshHost.id)
        )

        let keyStore = KeyStore()
        guard let key = keyStore.key(id: keyID) else {
            throw RunCommandPreflightError.noKeyConfigured(hostNickname: sshHost.nickname)
        }
        let material = try keyStore.privateKeyMaterial(
            for: key,
            reason: "run \u{201C}\(command)\u{201D} on \u{201C}\(sshHost.nickname)\u{201D} via Shortcuts"
        )

        // Detached, off the main actor, matching `SSHConnection.connect`'s
        // own split -- Citadel's types aren't Sendable-audited, so the
        // client is created and used entirely inside this task.
        let output = try await Task.detached {
            try await RunCommandExecutor.run(
                command: command,
                material: material,
                on: sshHost,
                hostKeyStore: hostKeyStore
            )
        }.value

        return .result(value: output)
    }
}
