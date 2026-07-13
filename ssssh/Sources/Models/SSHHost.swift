import Foundation

/// Named `SSHHost` (not `Host`) to avoid colliding with Foundation's `Host`.
struct SSHHost: Identifiable, Codable, Hashable {
    let id: UUID
    var nickname: String
    var hostname: String
    var port: Int
    var username: String
    var keyID: UUID?
    var startupCommand: String?
    /// SHA256 fingerprint of the host key accepted on first connect (TOFU).
    var knownHostFingerprint: String?

    init(
        id: UUID = UUID(),
        nickname: String,
        hostname: String,
        port: Int = 22,
        username: String,
        keyID: UUID? = nil,
        startupCommand: String? = nil,
        knownHostFingerprint: String? = nil
    ) {
        self.id = id
        self.nickname = nickname
        self.hostname = hostname
        self.port = port
        self.username = username
        self.keyID = keyID
        self.startupCommand = startupCommand
        self.knownHostFingerprint = knownHostFingerprint
    }
}
