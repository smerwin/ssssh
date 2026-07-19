import Citadel

extension Citadel.SSHClient {
    /// Connects to `host`, validating its host key with `validator`. Every
    /// call site in this app wants `reconnect: .never` -- reconnect
    /// decisions are owned by `SessionManager`/`SSHConnection`, not by
    /// Citadel's own reconnect machinery.
    static func connect(
        to host: SSHHost,
        authenticationMethod: SSHAuthenticationMethod,
        hostKeyValidator validator: SSHHostKeyValidator
    ) async throws -> Citadel.SSHClient {
        try await connect(
            host: host.hostname,
            port: host.port,
            authenticationMethod: authenticationMethod,
            hostKeyValidator: validator,
            reconnect: .never
        )
    }
}
