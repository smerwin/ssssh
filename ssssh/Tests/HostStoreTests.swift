import Testing
import Foundation
@testable import ssssh

@MainActor
struct HostStoreTests {
    private func makeHost(nickname: String = "test") -> SSHHost {
        SSHHost(nickname: nickname, hostname: "example.com", username: "me")
    }

    @Test func addPersistsAndIsVisibleToAFreshStoreInstance() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let store = HostStore(storageURL: tempURL)
        let host = makeHost()
        try store.add(host)
        #expect(store.hosts == [host])

        let reloaded = HostStore(storageURL: tempURL)
        #expect(reloaded.hosts == [host])
    }

    @Test func updateReplacesTheMatchingHostByID() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let store = HostStore(storageURL: tempURL)
        var host = makeHost()
        try store.add(host)

        host.nickname = "renamed"
        try store.update(host)

        #expect(store.hosts == [host])
        #expect(store.hosts.first?.nickname == "renamed")
    }

    @Test func updateForAnUnknownHostIsANoOp() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let store = HostStore(storageURL: tempURL)
        try store.add(makeHost())
        let unknown = makeHost(nickname: "not in store")

        try store.update(unknown)

        #expect(store.hosts.count == 1)
        #expect(store.hosts.first?.nickname == "test")
    }

    @Test func deleteRemovesTheHostAndPersists() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let store = HostStore(storageURL: tempURL)
        let host = makeHost()
        try store.add(host)
        try store.delete(host)

        #expect(store.hosts.isEmpty)
        let reloaded = HostStore(storageURL: tempURL)
        #expect(reloaded.hosts.isEmpty)
    }
}
