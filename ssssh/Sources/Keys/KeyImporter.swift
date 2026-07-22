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
    private static func categorize(_ error: Error, passphraseProvided: Bool) -> String {
        let description = String(describing: error)
        logger.error("Ed25519 decrypt/parse failed (passphraseProvided=\(passphraseProvided, privacy: .public)): \(description, privacy: .public)")
        let detail = technicalDetail(from: description)

        if description.contains("unsupportedCipher") {
            return "This key uses an encryption cipher ssssh doesn't support yet. (\(detail))"
        }
        if description.contains("unsupportedKDF") {
            return "This key uses a key-derivation method ssssh doesn't support yet. (\(detail))"
        }
        if !passphraseProvided {
            return "Couldn't decrypt this key. It may be passphrase-protected. (\(detail))"
        }
        return "Couldn't decrypt this key. Check the passphrase and try again. (\(detail))"
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
            throw ImportError.invalidKey(categorize(error, passphraseProvided: decryptionKey != nil))
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
