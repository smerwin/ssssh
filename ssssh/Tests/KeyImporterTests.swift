import Testing
import Foundation
import CryptoKit
@testable import ssssh

struct KeyImporterTests {
    @Test func roundTripsAFreshlyGeneratedUnencryptedKey() throws {
        let original = Curve25519.Signing.PrivateKey()
        let armored = original.makeSSHRepresentation(comment: "original-comment")

        let imported = try KeyImporter.importEd25519(
            fileContents: Data(armored.utf8),
            passphrase: "",
            comment: "my-label"
        )

        #expect(imported.algorithm == .ed25519)
        #expect(imported.privateKeyData == original.rawRepresentation)
        #expect(imported.publicKeyOpenSSH.hasPrefix("ssh-ed25519 "))
        #expect(imported.publicKeyOpenSSH.hasSuffix(" my-label"))
    }

    // The whole point of trimming: keys pasted from Notes, Mail, or saved
    // via different editors routinely pick up leading/trailing blank
    // lines or trailing whitespace that isn't part of the key itself.
    @Test func trimsSurroundingWhitespaceAndBlankLines() throws {
        let original = Curve25519.Signing.PrivateKey()
        let armored = original.makeSSHRepresentation(comment: "original-comment")
        let padded = "\n\n   \(armored)\n  \n\t\n"

        let imported = try KeyImporter.importEd25519(
            fileContents: Data(padded.utf8),
            passphrase: "",
            comment: "my-label"
        )

        #expect(imported.privateKeyData == original.rawRepresentation)
    }

    // Regression test: a key with CRLF line endings (e.g. generated on
    // Windows, or round-tripped through an editor that normalizes line
    // endings) used to fail with a misleading "That doesn't look like an
    // OpenSSH private key" error, because neither this app nor Citadel's
    // parser stripped "\r" when flattening the PEM body -- a stray "\r"
    // survived into what's supposed to be pure base64 and broke decoding,
    // even though the key itself was perfectly valid.
    @Test func importsAKeyWithCRLFLineEndings() throws {
        let original = Curve25519.Signing.PrivateKey()
        let armored = original.makeSSHRepresentation(comment: "original-comment")
        let crlf = armored.replacingOccurrences(of: "\n", with: "\r\n")

        let imported = try KeyImporter.importEd25519(
            fileContents: Data(crlf.utf8),
            passphrase: "",
            comment: "my-label"
        )
        #expect(imported.privateKeyData == original.rawRepresentation)
    }

    // A leading UTF-8 BOM (e.g. a key file saved as "UTF-8 with BOM" by
    // Notepad on Windows) doesn't break import -- Swift's UTF-8 decoding
    // strips it transparently. Kept as an explicit regression test since
    // it's the same class of cross-platform concern as the CRLF case above.
    @Test func importsAKeyWithALeadingUTF8BOM() throws {
        let original = Curve25519.Signing.PrivateKey()
        let armored = original.makeSSHRepresentation(comment: "original-comment")
        var withBOM = Data([0xEF, 0xBB, 0xBF])
        withBOM.append(Data(armored.utf8))

        let imported = try KeyImporter.importEd25519(
            fileContents: withBOM,
            passphrase: "",
            comment: "my-label"
        )
        #expect(imported.privateKeyData == original.rawRepresentation)
    }

    // Real ssh-keygen output (`ssh-keygen -t ed25519 -N "correct horse
    // battery staple"`), not a hand-built fixture -- covers the actual
    // encrypted-key decode path, not just our own re-encoding of it.
    private static let encryptedEd25519Fixture = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABDSpTKsNb
        yF8Y1B76vu5iG8AAAAGAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIO57eWnXHQc4jxZm
        OBdaSxoDdxWjbl23FSRkOw3JRTBEAAAAoArRPvTSW/bzvdCfN0FK70sWIF+GPZKyCKE2/t
        LOIcLYHv5hrdpMFIwvqz6/D6ZPAV8rn8t0MfhXnlvQWxDIjzdKOUGEpz/Hx1QYWEocwqWC
        TQV52WEiiXzFAtsoSpffQQ5QuJaQ7CdKCB0+pYCccXUk5pupiFrQhRyWfrQQVIWIEwj8MQ
        8g/RtIj2jRLGb+sw0/8XuVtoC5vKxkHeronCQ=
        -----END OPENSSH PRIVATE KEY-----
        """
    private static let encryptedEd25519Passphrase = "correct horse battery staple"

    @Test func decryptsAPassphraseProtectedKeyGivenTheRightPassphrase() throws {
        let imported = try KeyImporter.importEd25519(
            fileContents: Data(Self.encryptedEd25519Fixture.utf8),
            passphrase: Self.encryptedEd25519Passphrase,
            comment: "my-label"
        )
        #expect(imported.algorithm == .ed25519)
        #expect(imported.publicKeyOpenSSH.hasPrefix("ssh-ed25519 "))
    }

    @Test func rejectsAPassphraseProtectedKeyGivenTheWrongPassphrase() {
        #expect(throws: KeyImporter.ImportError.self) {
            try KeyImporter.importEd25519(
                fileContents: Data(Self.encryptedEd25519Fixture.utf8),
                passphrase: "definitely not it",
                comment: "my-label"
            )
        }
    }

    @Test func rejectsAPassphraseProtectedKeyGivenNoPassphrase() {
        #expect(throws: KeyImporter.ImportError.self) {
            try KeyImporter.importEd25519(
                fileContents: Data(Self.encryptedEd25519Fixture.utf8),
                passphrase: "",
                comment: "my-label"
            )
        }
    }

    // Real ssh-keygen output (`ssh-keygen -t rsa -b 2048 -N ""`) -- the
    // exact "I want to import an RSA key" case this app doesn't support.
    // See CLAUDE.md for why.
    private static let rsaFixture = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAABFwAAAAdzc2gtcn
        NhAAAAAwEAAQAAAQEAtmex0ocPDCNpWfziorWH7Ep41MthwGhNDHrxmucVOsNQedvQSbfz
        qFFIrkCFKfAC8fHZLEeEbgyJ5eD2ejODJeH1wmFdMqemGqINbFHKAiacuIv9jzV1Bi9YNC
        4Ex/6atkrojbyMe708xblsiZ3d1yGVmpCFfqfLGHauYMiRDyP6JoE8XCBywH6ZDjA6c1a5
        E2Jm3nohrDP61uo4JM+gp4xa20N8IY6fRDFEZisFw6fCfB68hpSQydIuKlXDgIfhttJYhw
        OaacAgv1wHwGd810m/fujWzccpzKflp/1IvzB5jQwP8friWsfOwI6jYqfG4jk7S1DdVZcN
        LHaUmy2tJwAAA9A8z+MjPM/jIwAAAAdzc2gtcnNhAAABAQC2Z7HShw8MI2lZ/OKitYfsSn
        jUy2HAaE0MevGa5xU6w1B529BJt/OoUUiuQIUp8ALx8dksR4RuDInl4PZ6M4Ml4fXCYV0y
        p6Yaog1sUcoCJpy4i/2PNXUGL1g0LgTH/pq2SuiNvIx7vTzFuWyJnd3XIZWakIV+p8sYdq
        5gyJEPI/omgTxcIHLAfpkOMDpzVrkTYmbeeiGsM/rW6jgkz6CnjFrbQ3whjp9EMURmKwXD
        p8J8HryGlJDJ0i4qVcOAh+G20liHA5ppwCC/XAfAZ3zXSb9+6NbNxynMp+Wn/Ui/MHmNDA
        /x+uJax87AjqNip8biOTtLUN1Vlw0sdpSbLa0nAAAAAwEAAQAAAQBpm2/hLEESDg6ZA0lU
        WzXvIM8EpRxbggfaCfSIcvJfq2WUqCfYBqET+rvR55kxxrxtyFCsyltqO+g7KByMc/aioE
        jh2e1Tvqz1Do4nANOsmx5x2ttbZt/yTMcMrvglsstwb75lEZ1kpxPghpLIupYOUGuFqdcg
        lZWI/G3Jq1YRJRD9tQqxdOYIdskdjLu1waD/0UYBOcIPlaqE7DGmcjoyIGdrYt1XRIk9A4
        dW+nD/HzKAdwZtlXOC/AcfPtqxk6hx+CzjzQG2/n4qBaz2l30rVV4dvj3nfPBjP5lnJFAy
        802FnwTSC7Tjpi1qYDjT9qqPb/nV0r3GjbI9jUGixrZBAAAAgQCuygipttCf1m04U97cQl
        sm8J2oDnkIfke5rbqg9X7p2+k8T7img+5lWPAfeV2dnI6y0iQ6FPf4LPGD5Mlu1DeY1Snu
        4QRsuPE8+XH1ddr+xpyB3c9INQTHA9pVVCCBaGCQgBBTuk4tyY30978fq6cSn0DFReElVj
        uqZPZjxZ2BAwAAAIEA3xVHxqxDPsvgYs++t38QIhoauXlAkM9y/4rl3p2xTEpZ4P5Bwt0D
        6moAOzzF0fRnJAMsIm37DHpxWW+9/0+t8gJjIcKfdJkIBtp8OvlB9l0n/jrNmOcIyKMdEN
        MRFIhxabIrr5kWJ7SXC+ST3O0ssMQXuEigJtj52RtKnJneEJ0AAACBANFR2E2l74DwzquO
        BBjgwUgbic99g8/y/jpt6+i0KSyOPgQerZKpaDamZea1jfQAXiHLTVcVOiMLpMU3V07ZC9
        lSThTYL90H7vVLxvqE8a9DOQ/itRkNXrzq0wR/3+b7TAogonOODfj+avAxpxfujGwOuyr+
        SZkCEaytfBJzyb+TAAAAE3Rlc3QtaW1wb3J0LWZpeHR1cmUBAgMEBQYH
        -----END OPENSSH PRIVATE KEY-----
        """

    @Test func rejectsAnRSAKeyWithAClearUnsupportedAlgorithmError() throws {
        #expect(throws: KeyImporter.ImportError.self) {
            try KeyImporter.importEd25519(fileContents: Data(Self.rsaFixture.utf8), passphrase: "", comment: "my-label")
        }

        do {
            _ = try KeyImporter.importEd25519(fileContents: Data(Self.rsaFixture.utf8), passphrase: "", comment: "my-label")
            Issue.record("expected importEd25519 to throw for an RSA key")
        } catch KeyImporter.ImportError.unsupportedAlgorithm(let type) {
            #expect(type == "RSA")
        } catch {
            Issue.record("expected .unsupportedAlgorithm, got \(error)")
        }
    }

    @Test func rejectsGarbageInput() {
        #expect(throws: KeyImporter.ImportError.self) {
            try KeyImporter.importEd25519(fileContents: Data("not a key".utf8), passphrase: "", comment: "my-label")
        }
    }
}
