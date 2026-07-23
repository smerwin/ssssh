import Foundation

enum RunCommandPreflightError: LocalizedError {
    case noKeyConfigured(hostNickname: String)
    case hostKeyNotTrusted(hostNickname: String)

    var errorDescription: String? {
        switch self {
        case .noKeyConfigured(let nickname):
            return "\(nickname) doesn't have an SSH key configured. Run Command only works with key-based hosts -- there's no way to prompt for a password from Shortcuts."
        case .hostKeyNotTrusted(let nickname):
            return "\(nickname)'s host key hasn't been trusted yet. Open ssssh and connect to \(nickname) once first, then run this shortcut again."
        }
    }
}

/// Must run before any connection is attempted. `HostKeyStore.evaluate`
/// waits indefinitely for a Trust/Cancel decision on an unrecognized host
/// key, resolved only by the confirmation sheet in `sssshApp`'s
/// `WindowGroup` -- with no window ever presented (a background
/// Shortcuts/Siri invocation with `openAppWhenRun == false`), that wait
/// never resolves. Checking the host is already key-based and already
/// trusted here, synchronously and before touching the network, avoids
/// ever reaching that hang.
enum RunCommandPreflight {
    static func validate(host: SSHHost, trustedFingerprint: String?) throws -> UUID {
        guard let keyID = host.keyID else {
            throw RunCommandPreflightError.noKeyConfigured(hostNickname: host.nickname)
        }
        guard trustedFingerprint != nil else {
            throw RunCommandPreflightError.hostKeyNotTrusted(hostNickname: host.nickname)
        }
        return keyID
    }
}
