import Foundation

/// Implements the "copy key to server" flow described in the README:
/// authenticate once with a password, then ensure `~/.ssh/authorized_keys`
/// on the remote host contains the given public key, creating `~/.ssh`
/// with `0700` and the file with `0600` if needed. The password is held
/// only in memory for the duration of the call and is never persisted.
enum SSHCopyID {
    enum CopyIDError: Error {
        case notImplemented
    }

    static func copyKey(
        _ publicKeyOpenSSH: String,
        to host: SSHHost,
        password: String
    ) async throws {
        // Milestone 3 work: open a session with password auth, run the
        // mkdir/append/chmod sequence, then reconnect with the new key to
        // confirm success before returning.
        throw CopyIDError.notImplemented
    }
}
