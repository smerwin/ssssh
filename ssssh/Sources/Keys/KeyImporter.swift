import Foundation
import CryptoKit
import Citadel
import os

/// Imports an existing Ed25519 private key from OpenSSH's standard
/// `-----BEGIN OPENSSH PRIVATE KEY-----` armored format -- the format
/// `ssh-keygen` produces by default.
///
/// RSA and ECDSA P-256/P-384 import aren't supported: see the "Importing
/// RSA/ECDSA private keys" note in CLAUDE.md for exactly why, and what it
/// would take to add.
enum KeyImporter {
    private static let logger = Logger(subsystem: "com.smerwin.ssssh", category: "KeyImporter")

    enum ImportError: LocalizedError {
        case unsupportedAlgorithm(String)
        case invalidKey(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedAlgorithm(let type):
                return "ssssh can only import Ed25519 keys right now, not \(type)."
            case .invalidKey(let reason):
                return reason
            }
        }
    }

    /// Citadel's own decrypt/parse errors (`InvalidOpenSSHKey`, `OpenSSH.KeyError`)
    /// are either module-internal or expose only an internal `reason` field --
    /// nothing catchable or readable through their public API. Swift's default,
    /// reflection-based `String(describing:)` still reveals the underlying case
    /// name (e.g. `InvalidOpenSSHKey(reason: "invalidCheck")`,
    /// `UnsupportedFeature: unsupportedCipher`) because reflection isn't subject
    /// to access control, only direct member access is. That's the only way to
    /// tell "wrong passphrase" (garbage-decrypted bytes failing a downstream
    /// structural check, e.g. `invalidCheck`/`invalidPadding`/`missingComment`)
    /// apart from "ssssh doesn't support this key's cipher/KDF at all" (a
    /// `UnsupportedFeature` case) -- two very different problems that used to
    /// produce the exact same "check your passphrase" message.
    ///
    /// The extracted detail (e.g. "invalidCheck") is appended to the
    /// user-facing message, not just logged -- a beta tester can then report
    /// back the exact failure reason without needing to pull device console
    /// logs, which for a remote TestFlight tester usually isn't practical.
    private static func categorize(_ error: Error, passphraseProvided: Bool, armoredKey: String) -> String {
        let description = String(describing: error)
        logger.error("Ed25519 decrypt/parse failed (passphraseProvided=\(passphraseProvided, privacy: .public)): \(description, privacy: .public)")
        let detail = technicalDetail(from: description)

        if description.contains("unsupportedCipher") {
            if let cipher = sniffCipherAndKDFNames(from: armoredKey).cipher {
                return "This key is encrypted with \u{201C}\(cipher)\u{201D}, which ssssh doesn't support decrypting yet -- only unencrypted keys and ones using aes128-ctr/aes256-ctr are. Re-encrypt it with a supported cipher (e.g. \u{201C}ssh-keygen -p -a 16 -Z aes256-ctr -f keyfile\u{201D}) and try again."
            }
            return "This key uses an encryption cipher ssssh doesn't support yet. (\(detail))"
        }
        if description.contains("unsupportedKDF") {
            if let kdf = sniffCipherAndKDFNames(from: armoredKey).kdf {
                return "This key uses \u{201C}\(kdf)\u{201D} key derivation, which ssssh doesn't support yet."
            }
            return "This key uses a key-derivation method ssssh doesn't support yet. (\(detail))"
        }
        if !passphraseProvided {
            return "Couldn't decrypt this key. It may be passphrase-protected. (\(detail))"
        }
        return "Couldn't decrypt this key. Check the passphrase and try again. (\(detail))"
    }

    /// Independently re-reads just the cipher/KDF name fields from the
    /// key's own OpenSSH binary header (`openssh-key-v1\0` magic, then two
    /// back-to-back length-prefixed SSH strings) -- deliberately not full
    /// key parsing or decryption. This exists because Citadel's own
    /// `InvalidOpenSSHKey.unsupportedFeature` error never carries the
    /// actual offending name: the raw string is read and discarded inside
    /// Citadel's parser the moment `Cipher(rawValue:)`/`KDFType(rawValue:)`
    /// returns nil, so "which cipher/KDF, specifically" is otherwise
    /// unrecoverable from the thrown error alone. Best-effort: returns nil
    /// for whichever field it can't read rather than throwing, since this
    /// only ever runs to enrich an already-failing import's error message.
    private static func sniffCipherAndKDFNames(from armoredKey: String) -> (cipher: String?, kdf: String?) {
        var body = armoredKey.replacingOccurrences(of: "\n", with: "")
        let prefix = "-----BEGIN OPENSSH PRIVATE KEY-----"
        let suffix = "-----END OPENSSH PRIVATE KEY-----"
        guard body.hasPrefix(prefix), body.hasSuffix(suffix) else { return (nil, nil) }
        body.removeLast(suffix.count)
        body.removeFirst(prefix.count)
        guard let data = Data(base64Encoded: body) else { return (nil, nil) }

        let bytes = [UInt8](data)
        let magic = Array("openssh-key-v1".utf8) + [0x00]
        guard bytes.count > magic.count, Array(bytes.prefix(magic.count)) == magic else { return (nil, nil) }

        var offset = magic.count
        func readSSHString() -> String? {
            guard offset + 4 <= bytes.count else { return nil }
            let length = bytes[offset..<offset + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            offset += 4
            guard length <= UInt32(bytes.count - offset) else { return nil }
            defer { offset += Int(length) }
            return String(bytes: bytes[offset..<offset + Int(length)], encoding: .utf8)
        }

        return (readSSHString(), readSSHString())
    }

    /// Pulls the short case name (e.g. "invalidCheck") out of
    /// `InvalidOpenSSHKey`'s reflected `InvalidOpenSSHKey(reason: "invalidCheck")`
    /// description. Falls back to the full reflected description for error
    /// types that don't have a `reason: "..."` field at all (e.g.
    /// `OpenSSH.KeyError`'s bare `missingDecryptionKey`/`cryptoError` cases).
    private static func technicalDetail(from description: String) -> String {
        guard
            let markerRange = description.range(of: "reason: \""),
            let endQuote = description[markerRange.upperBound...].firstIndex(of: "\"")
        else {
            return description
        }
        return String(description[markerRange.upperBound..<endQuote])
    }

    static func importEd25519(fileContents: Data, passphrase: String, comment: String) throws -> KeyGenerator.GeneratedKey {
        guard let text = String(data: fileContents, encoding: .utf8) else {
            throw ImportError.invalidKey("That file isn't readable as text.")
        }
        // Normalize CRLF/CR line endings to plain LF *before* trimming --
        // both Citadel's SSHKeyDetection and its OpenSSH.PrivateKey parser
        // only strip "\n" when flattening the PEM body down to base64, not
        // "\r". A key with CRLF line endings (e.g. generated on Windows, or
        // round-tripped through an editor that normalizes line endings)
        // otherwise leaves a stray "\r" embedded in what's supposed to be
        // pure base64, which fails to decode and surfaces as a generic,
        // misleading "That doesn't look like an OpenSSH private key" --
        // even though the key itself is perfectly valid.
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)

        let detected: SSHKeyType
        do {
            detected = try SSHKeyDetection.detectPrivateKeyType(from: trimmed)
        } catch {
            throw ImportError.invalidKey("That doesn't look like an OpenSSH private key.")
        }
        guard detected == .ed25519 else {
            throw ImportError.unsupportedAlgorithm(detected.description)
        }

        let decryptionKey = passphrase.isEmpty ? nil : Data(passphrase.utf8)
        let privateKey: Curve25519.Signing.PrivateKey
        do {
            privateKey = try Curve25519.Signing.PrivateKey(sshEd25519: trimmed, decryptionKey: decryptionKey)
        } catch {
            throw ImportError.invalidKey(categorize(error, passphraseProvided: decryptionKey != nil, armoredKey: trimmed))
        }

        let publicKeyLine = KeyGenerator.openSSHLine(
            keyType: "ssh-ed25519",
            publicKeyBytes: privateKey.publicKey.rawRepresentation,
            comment: comment
        )
        return KeyGenerator.GeneratedKey(
            algorithm: .ed25519,
            privateKeyData: privateKey.rawRepresentation,
            publicKeyOpenSSH: publicKeyLine
        )
    }
}
