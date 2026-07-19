import Foundation

/// Resolves a file inside the app's Application Support directory,
/// creating the directory if it doesn't exist yet.
func applicationSupportURL(filename: String) -> URL {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent(filename)
}

/// Generic JSON-file-backed persistence shared by `HostStore`, `KeyStore`,
/// and `HostKeyStore`: read-with-fallback on load, atomic write on save.
struct JSONFileStore<T: Codable> {
    let url: URL

    func load(default defaultValue: T) -> T {
        guard let data = try? Data(contentsOf: url) else { return defaultValue }
        return (try? JSONDecoder().decode(T.self, from: data)) ?? defaultValue
    }

    func save(_ value: T) throws {
        let data = try JSONEncoder().encode(value)
        try data.write(to: url, options: .atomic)
    }
}
