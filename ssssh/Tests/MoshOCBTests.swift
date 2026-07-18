import Foundation
import Testing
@testable import ssssh

/// Validates `MoshOCB` against RFC 7253 Appendix A's published (K, N, A, P, C)
/// test vectors -- the ground truth for this from-scratch AES-128-OCB
/// implementation, since mosh's wire protocol requires it to be bit-exact
/// with any standard OCB implementation a real `mosh-server` uses. Vectors
/// were parsed programmatically out of the RFC text rather than hand-typed,
/// to rule out transcription mistakes in these 100+ character hex strings.
struct MoshOCBTests {
    private static let key = hex("000102030405060708090A0B0C0D0E0F")

    private static func hex(_ s: String) -> [UInt8] {
        var bytes = [UInt8]()
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            bytes.append(UInt8(String(chars[i...i + 1]), radix: 16)!)
            i += 2
        }
        return bytes
    }

    @Test("RFC 7253 Appendix A vectors", arguments: [
        (nonce: "BBAA99887766554433221100", associatedData: "", plaintext: "", ciphertext: "785407BFFFC8AD9EDCC5520AC9111EE6"),
        (nonce: "BBAA99887766554433221101", associatedData: "0001020304050607", plaintext: "0001020304050607", ciphertext: "6820B3657B6F615A5725BDA0D3B4EB3A257C9AF1F8F03009"),
        (nonce: "BBAA99887766554433221102", associatedData: "0001020304050607", plaintext: "", ciphertext: "81017F8203F081277152FADE694A0A00"),
        (nonce: "BBAA99887766554433221103", associatedData: "", plaintext: "0001020304050607", ciphertext: "45DD69F8F5AAE72414054CD1F35D82760B2CD00D2F99BFA9"),
        (nonce: "BBAA99887766554433221104", associatedData: "000102030405060708090A0B0C0D0E0F", plaintext: "000102030405060708090A0B0C0D0E0F", ciphertext: "571D535B60B277188BE5147170A9A22C3AD7A4FF3835B8C5701C1CCEC8FC3358"),
        (nonce: "BBAA99887766554433221105", associatedData: "000102030405060708090A0B0C0D0E0F", plaintext: "", ciphertext: "8CF761B6902EF764462AD86498CA6B97"),
        (nonce: "BBAA99887766554433221106", associatedData: "", plaintext: "000102030405060708090A0B0C0D0E0F", ciphertext: "5CE88EC2E0692706A915C00AEB8B2396F40E1C743F52436BDF06D8FA1ECA343D"),
        (nonce: "BBAA99887766554433221107", associatedData: "000102030405060708090A0B0C0D0E0F1011121314151617", plaintext: "000102030405060708090A0B0C0D0E0F1011121314151617", ciphertext: "1CA2207308C87C010756104D8840CE1952F09673A448A122C92C62241051F57356D7F3C90BB0E07F"),
        (nonce: "BBAA99887766554433221108", associatedData: "000102030405060708090A0B0C0D0E0F1011121314151617", plaintext: "", ciphertext: "6DC225A071FC1B9F7C69F93B0F1E10DE"),
        (nonce: "BBAA99887766554433221109", associatedData: "", plaintext: "000102030405060708090A0B0C0D0E0F1011121314151617", ciphertext: "221BD0DE7FA6FE993ECCD769460A0AF2D6CDED0C395B1C3CE725F32494B9F914D85C0B1EB38357FF"),
        (nonce: "BBAA9988776655443322110A", associatedData: "000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F", plaintext: "000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F", ciphertext: "BD6F6C496201C69296C11EFD138A467ABD3C707924B964DEAFFC40319AF5A48540FBBA186C5553C68AD9F592A79A4240"),
        (nonce: "BBAA9988776655443322110B", associatedData: "000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F", plaintext: "", ciphertext: "FE80690BEE8A485D11F32965BC9D2A32"),
        (nonce: "BBAA9988776655443322110C", associatedData: "", plaintext: "000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F", ciphertext: "2942BFC773BDA23CABC6ACFD9BFD5835BD300F0973792EF46040C53F1432BCDFB5E1DDE3BC18A5F840B52E653444D5DF"),
        (nonce: "BBAA9988776655443322110D", associatedData: "000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F2021222324252627", plaintext: "000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F2021222324252627", ciphertext: "D5CA91748410C1751FF8A2F618255B68A0A12E093FF454606E59F9C1D0DDC54B65E8628E568BAD7AED07BA06A4A69483A7035490C5769E60"),
        (nonce: "BBAA9988776655443322110E", associatedData: "000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F2021222324252627", plaintext: "", ciphertext: "C5CD9D1850C141E358649994EE701B68"),
        (nonce: "BBAA9988776655443322110F", associatedData: "", plaintext: "000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F2021222324252627", ciphertext: "4412923493C57D5DE0D700F753CCE0D1D2D95060122E9F15A5DDBFC5787E50B5CC55EE507BCB084E479AD363AC366B95A98CA5F3000B1479"),
    ])
    func rfc7253Vector(_ vector: (nonce: String, associatedData: String, plaintext: String, ciphertext: String)) throws {
        let n = Self.hex(vector.nonce)
        let a = Self.hex(vector.associatedData)
        let p = Self.hex(vector.plaintext)
        let expectedC = Self.hex(vector.ciphertext)

        let encrypted = MoshOCB.encrypt(key: Self.key, nonce: n, associatedData: a, plaintext: p)
        #expect(encrypted == expectedC)

        let decrypted = try MoshOCB.decrypt(key: Self.key, nonce: n, associatedData: a, ciphertext: expectedC)
        #expect(decrypted == p)
    }

    @Test("Tampered ciphertext fails authentication")
    func tamperedCiphertextFailsAuthentication() {
        let n = Self.hex("BBAA99887766554433221104")
        let a = Self.hex("000102030405060708090A0B0C0D0E0F")
        var c = Self.hex("571D535B60B277188BE5147170A9A22C3AD7A4FF3835B8C5701C1CCEC8FC3358")
        c[0] ^= 0x01
        #expect(throws: MoshOCB.AuthenticationFailure.self) {
            try MoshOCB.decrypt(key: Self.key, nonce: n, associatedData: a, ciphertext: c)
        }
    }
}
