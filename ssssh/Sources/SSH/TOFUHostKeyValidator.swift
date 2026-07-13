import Foundation
import NIO
import NIOSSH
import Citadel

/// Bridges NIOSSH's host key validation callback to `HostKeyStore`'s
/// trust-on-first-use flow.
final class TOFUHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let host: SSHHost
    private let hostKeyStore: HostKeyStore

    init(host: SSHHost, hostKeyStore: HostKeyStore) {
        self.host = host
        self.hostKeyStore = hostKeyStore
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let fingerprint = HostKeyFingerprint.sha256(of: hostKey)
        let host = self.host
        let hostKeyStore = self.hostKeyStore

        Task {
            do {
                try await hostKeyStore.evaluate(host: host, fingerprint: fingerprint)
                validationCompletePromise.succeed(())
            } catch {
                validationCompletePromise.fail(error)
            }
        }
    }
}

extension SSHHostKeyValidator {
    static func tofu(host: SSHHost, hostKeyStore: HostKeyStore) -> SSHHostKeyValidator {
        .custom(TOFUHostKeyValidator(host: host, hostKeyStore: hostKeyStore))
    }
}
