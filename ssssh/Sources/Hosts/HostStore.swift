import Foundation
import Observation

/// Owns the list of saved host profiles. Local-only persistence as JSON;
/// no cloud sync in v1 (see README "Non-goals").
@Observable
final class HostStore {
    private(set) var hosts: [SSHHost] = []

    private let fileStore: JSONFileStore<[SSHHost]>

    init(storageURL: URL = applicationSupportURL(filename: "hosts.json")) {
        fileStore = JSONFileStore(url: storageURL)
        hosts = fileStore.load(default: [])
    }

    func host(id: UUID) -> SSHHost? {
        hosts.first { $0.id == id }
    }

    func add(_ host: SSHHost) throws {
        hosts.append(host)
        try save()
    }

    func update(_ host: SSHHost) throws {
        guard let index = hosts.firstIndex(where: { $0.id == host.id }) else { return }
        hosts[index] = host
        try save()
    }

    func delete(_ host: SSHHost) throws {
        hosts.removeAll { $0.id == host.id }
        try save()
    }

    private func save() throws {
        try fileStore.save(hosts)
    }
}
