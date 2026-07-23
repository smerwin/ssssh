import AppIntents

struct RunCommandIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Command"
    static let description = IntentDescription("Runs a command over SSH on a saved host and returns its output.")

    /// `true`, confirmed necessary on a real device: with this `false`,
    /// `Keychain.load`'s Face ID/Touch ID prompt can't be shown at all --
    /// `SecItemCopyMatching` fails immediately with
    /// `KeychainError.interactionNotAllowed`, even when the shortcut is run
    /// by tapping it directly in the Shortcuts app, not just from an
    /// unattended automation. See CLAUDE.md's Apple Shortcuts section for
    /// the confirmed failure and why this sacrifices the "runs silently
    /// from an automation" ideal to keep the feature usable at all.
    static let openAppWhenRun: Bool = true

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
