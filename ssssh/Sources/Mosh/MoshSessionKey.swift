import Foundation
import Security

/// Mosh's own printable session-key format: 16 raw bytes encoded as
/// standard base64 with the guaranteed trailing "==" padding stripped off
/// (base64 of exactly 16 bytes always ends in "==", since 16 mod 3 == 1).
/// This is bit-for-bit `Crypto::Base64Key` from mosh's `crypto.cc`, not a
/// generic base64 helper -- `mosh-server`'s `MOSH CONNECT <port> <key>`
/// reply prints exactly this 22-character form, and this is what
/// `MoshBootstrap` parses out of it.
enum MoshSessionKey {
    struct InvalidKey: Error {}

    /// Parses a 22-character printable key (as printed by `mosh-server`)
    /// into its 16 raw key bytes.
    static func parse(printableKey printable: String) throws -> [UInt8] {
        guard printable.count == 22 else { throw InvalidKey() }
        guard let data = Data(base64Encoded: printable + "==") else { throw InvalidKey() }
        guard data.count == 16 else { throw InvalidKey() }
        let bytes = [UInt8](data)
        // Mirrors the round-trip check in mosh's own Base64Key constructor:
        // reject any printable string that isn't the canonical encoding of
        // its own decoded bytes, guarding against non-canonical base64
        // padding bits that would otherwise silently decode without error.
        guard printableKey(for: bytes) == printable else { throw InvalidKey() }
        return bytes
    }

    /// Encodes 16 raw key bytes into mosh's 22-character printable form.
    static func printableKey(for bytes: [UInt8]) -> String {
        precondition(bytes.count == 16)
        let base64 = Data(bytes).base64EncodedString()
        precondition(base64.hasSuffix("=="))
        return String(base64.dropLast(2))
    }

    /// A fresh random 128-bit key, for tests -- mosh's client never
    /// generates its own session key in practice; only `mosh-server` does,
    /// and this app parses that one out via `MoshBootstrap`.
    static func generateRandomForTesting() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess)
        return bytes
    }
}
