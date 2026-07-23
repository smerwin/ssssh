import Foundation

/// Named `SSHHost` (not `Host`) to avoid colliding with Foundation's `Host`.
/// Explicit `Sendable` since this now crosses into `AppIntents`/detached-task
/// boundaries (see `RunCommandIntent`), not just implicit same-module
/// inference.
struct SSHHost: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var nickname: String
    var hostname: String
    var port: Int
    var username: String
    var keyID: UUID?
    var startupCommand: String?

    init(
        id: UUID = UUID(),
        nickname: String,
        hostname: String,
        port: Int = 22,
        username: String,
        keyID: UUID? = nil,
        startupCommand: String? = nil
    ) {
        self.id = id
        self.nickname = nickname
        self.hostname = hostname
        self.port = port
        self.username = username
        self.keyID = keyID
        self.startupCommand = startupCommand
    }
}
