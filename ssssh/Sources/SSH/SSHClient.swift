import Foundation

/// Interactive shell/PTY session over SSH. This scaffold defines the shape
/// of the API; milestone 2 ("Connect + terminal") implements it on top of
/// Citadel, including Ed25519 authentication, PTY allocation, window
/// resizing, and known_hosts/TOFU verification.
protocol SSHClientSession {
    func send(_ bytes: [UInt8]) async throws
    func resize(cols: Int, rows: Int) async throws
    func close() async
}

enum SSHClientError: Error {
    case notImplemented
}

enum SSHClient {
    static func connectShell(to host: SSHHost, onOutput: @escaping ([UInt8]) -> Void) async throws -> SSHClientSession {
        throw SSHClientError.notImplemented
    }
}
