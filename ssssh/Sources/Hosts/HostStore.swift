import Foundation
import Observation

/// Owns the list of saved host profiles. Local-only persistence as JSON;
/// no cloud sync in v1 (see README "Non-goals").
@Observable
final class HostStore {
    private(set) var hosts: [SSHHost] = []

    private let storageURL: URL

    init(storageURL: URL = HostStore.defaultStorageURL()) {
        self.storageURL = storageURL
        load()
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

    private func load() {
        guard let data = try? Data(contentsOf: storageURL) else { return }
        hosts = (try? JSONDecoder().decode([SSHHost].self, from: data)) ?? []
    }

    private func save() throws {
        let data = try JSONEncoder().encode(hosts)
        try data.write(to: storageURL, options: .atomic)
    }

    private static func defaultStorageURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("hosts.json")
    }
}
