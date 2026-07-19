import Foundation
import Observation

/// Thrown by the TOFU validator when a host presents a key that doesn't
/// match the fingerprint we previously trusted for it.
struct HostKeyMismatch: Error {
    let hostNickname: String
    let expected: String
    let presented: String
}

/// Thrown when the user declines to trust a new host key.
struct HostKeyRejected: Error {}

/// A host key awaiting user confirmation (TOFU: trust on first use).
struct PendingHostKeyConfirmation: Identifiable {
    let id = UUID()
    let host: SSHHost
    let fingerprint: String
    let decide: (Bool) -> Void
}

/// Bridges Citadel's synchronous-ish host key validation callback to an
/// async SwiftUI confirmation dialog, and persists trusted fingerprints
/// per host (keyed by `SSHHost.id`) so subsequent connects can be
/// validated without prompting.
///
/// New hosts: the fingerprint is shown to the user for a Trust/Cancel
/// decision. Known hosts: the presented key must match the stored
/// fingerprint exactly, or the connection is refused with
/// `HostKeyMismatch` -- there is no in-the-moment override, by design;
/// see README "Security notes".
/// `@unchecked Sendable`: `@MainActor`-isolated, so its mutable state is
/// already serialized onto the main actor; `evaluate` is the one method
/// meant to be called from other isolation domains (see its doc comment).
@MainActor
@Observable
final class HostKeyStore: @unchecked Sendable {
    private(set) var trustedFingerprints: [UUID: String] = [:]
    var pendingConfirmation: PendingHostKeyConfirmation?

    private let fileStore: JSONFileStore<[String: String]>

    init(storageURL: URL = applicationSupportURL(filename: "known_hosts.json")) {
        fileStore = JSONFileStore(url: storageURL)
        load()
    }

    func fingerprint(for hostID: UUID) -> String? {
        trustedFingerprints[hostID]
    }

    /// Called from the NIOSSH validation callback (may be on a NIO event
    /// loop thread); hops to the main actor to consult/update state.
    nonisolated func evaluate(host: SSHHost, fingerprint: String) async throws {
        // NB: the `return` inside this closure only exits the closure
        // itself, not `evaluate` -- without capturing and checking its
        // result, execution falls through to the confirmation-dialog
        // path below on *every* connection, even to an already-trusted
        // host. Bug fixed here; don't reintroduce it.
        let alreadyTrusted = try await MainActor.run { () -> Bool in
            if let known = self.trustedFingerprints[host.id] {
                guard known == fingerprint else {
                    throw HostKeyMismatch(hostNickname: host.nickname, expected: known, presented: fingerprint)
                }
                return true
            }
            return false
        }
        if alreadyTrusted {
            return
        }

        let trusted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            Task { @MainActor in
                self.pendingConfirmation = PendingHostKeyConfirmation(host: host, fingerprint: fingerprint) { decision in
                    continuation.resume(returning: decision)
                }
            }
        }

        await MainActor.run {
            self.pendingConfirmation = nil
            if trusted {
                self.trustedFingerprints[host.id] = fingerprint
                try? self.save()
            }
        }

        if !trusted {
            throw HostKeyRejected()
        }
    }

    /// Removes a stored fingerprint, e.g. after a legitimate server
    /// reinstall, so the next connect goes through TOFU again.
    func forget(hostID: UUID) {
        trustedFingerprints.removeValue(forKey: hostID)
        try? save()
    }

    private func load() {
        let decoded = fileStore.load(default: [:])
        trustedFingerprints = Dictionary(uniqueKeysWithValues: decoded.compactMap { key, value in
            UUID(uuidString: key).map { ($0, value) }
        })
    }

    private func save() throws {
        let encodable = Dictionary(uniqueKeysWithValues: trustedFingerprints.map { ($0.key.uuidString, $0.value) })
        try fileStore.save(encodable)
    }
}
