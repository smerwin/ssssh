import AppIntents

/// Wraps `SSHHost` for Shortcuts' host-picker parameter (see
/// `RunCommandIntent`). Wraps the whole host, not just a subset of fields,
/// so `keyID`/`port`/`username` are available without a second lookup and
/// this is naturally reusable by a future "Connect" intent.
struct SSHHostEntity: AppEntity {
    let host: SSHHost
    var id: UUID { host.id }

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "SSH Host"
    static let defaultQuery = SSHHostEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(host.nickname)", subtitle: "\(host.username)@\(host.hostname)")
    }
}

struct SSHHostEntityQuery: EntityQuery {
    func entities(for identifiers: [SSHHostEntity.ID]) async throws -> [SSHHostEntity] {
        HostStore().hosts.filter { identifiers.contains($0.id) }.map(SSHHostEntity.init)
    }

    func suggestedEntities() async throws -> [SSHHostEntity] {
        HostStore().hosts.map(SSHHostEntity.init)
    }
}
