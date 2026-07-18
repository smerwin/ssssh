import CommonCrypto
import Foundation

/// AES-128 in OCB mode (RFC 7253), implemented directly from the RFC's
/// pseudocode -- there is no OCB implementation in CryptoKit, and no mature
/// Swift package for it either, so this can't be assembled from an existing
/// library the way the rest of this app's crypto is (see `KeyGenerator`,
/// `HostKeyStore`). Mosh's wire protocol requires exactly this construction
/// (AES-128, a 12-byte nonce, a 128-bit tag, no associated data) to
/// interoperate with a real, unmodified `mosh-server` -- this is not
/// negotiable the way TLS cipher suites are.
///
/// Validated against RFC 7253 Appendix A's published (K, N, A, P, C) test
/// vectors in `MoshOCBTests`, covering empty/partial/full/multi-block
/// plaintexts and associated data. That coverage is what earns trust here,
/// not the code's resemblance to any reference implementation -- nothing in
/// this file was transliterated from mosh's own `ocb_internal.cc` (which is
/// Ted Krovetz's heavily vectorized reference code); it was written
/// clean-room from the RFC text and then checked against the vectors.
///
/// Nonce reuse under a single key is catastrophic for both privacy and
/// authenticity in OCB. Callers (`MoshSession`) must guarantee a nonce is
/// never reused for a given key -- mosh does this with a monotonic
/// sequence number per direction, never resetting it for the life of a
/// session.
enum MoshOCB {
    static let blockSize = 16
    /// The only tag length mosh's wire protocol uses (128 bits).
    static let tagLength = 16

    struct AuthenticationFailure: Error {}

    /// Encrypts `plaintext` under `key` (16 bytes), returning ciphertext
    /// with the 16-byte authentication tag appended. `nonce` must be 1-15
    /// bytes and never reused for this `key`.
    static func encrypt(key: [UInt8], nonce: [UInt8], associatedData: [UInt8] = [], plaintext: [UInt8]) -> [UInt8] {
        precondition(key.count == 16)
        precondition((1...15).contains(nonce.count))

        let lTable = LTable(key: key)
        var offset = initialOffset(key: key, nonce: nonce)
        var checksum = [UInt8](repeating: 0, count: blockSize)
        var ciphertext = [UInt8]()
        ciphertext.reserveCapacity(plaintext.count + tagLength)

        let fullBlockCount = plaintext.count / blockSize
        for i in 0..<fullBlockCount {
            offset = xor(offset, lTable.l(for: (i + 1).trailingZeroBitCount))
            let pBlock = Array(plaintext[(i * blockSize)..<((i + 1) * blockSize)])
            ciphertext.append(contentsOf: xor(offset, aesEncryptBlock(xor(pBlock, offset), key: key)))
            checksum = xor(checksum, pBlock)
        }

        let remainder = Array(plaintext[(fullBlockCount * blockSize)...])
        let tag: [UInt8]
        if remainder.isEmpty {
            tag = xor(
                aesEncryptBlock(xor(xor(checksum, offset), lTable.lDollar), key: key),
                hash(key: key, lTable: lTable, associatedData: associatedData)
            )
        } else {
            let offsetStar = xor(offset, lTable.lStar)
            let pad = aesEncryptBlock(offsetStar, key: key)
            ciphertext.append(contentsOf: xor(remainder, Array(pad.prefix(remainder.count))))
            checksum = xor(checksum, pad128(remainder))
            tag = xor(
                aesEncryptBlock(xor(xor(checksum, offsetStar), lTable.lDollar), key: key),
                hash(key: key, lTable: lTable, associatedData: associatedData)
            )
        }

        ciphertext.append(contentsOf: tag)
        return ciphertext
    }

    /// Decrypts and authenticates `ciphertext` (as produced by `encrypt`),
    /// throwing `AuthenticationFailure` if the tag doesn't match -- this
    /// must never be swallowed and treated as "no data": an invalid tag
    /// means the packet was corrupted, replayed, or forged.
    static func decrypt(key: [UInt8], nonce: [UInt8], associatedData: [UInt8] = [], ciphertext: [UInt8]) throws -> [UInt8] {
        precondition(key.count == 16)
        precondition((1...15).contains(nonce.count))
        guard ciphertext.count >= tagLength else { throw AuthenticationFailure() }

        let bodyLength = ciphertext.count - tagLength
        let body = Array(ciphertext.prefix(bodyLength))
        let providedTag = Array(ciphertext.suffix(tagLength))

        let lTable = LTable(key: key)
        var offset = initialOffset(key: key, nonce: nonce)
        var checksum = [UInt8](repeating: 0, count: blockSize)
        var plaintext = [UInt8]()
        plaintext.reserveCapacity(bodyLength)

        let fullBlockCount = bodyLength / blockSize
        for i in 0..<fullBlockCount {
            offset = xor(offset, lTable.l(for: (i + 1).trailingZeroBitCount))
            let cBlock = Array(body[(i * blockSize)..<((i + 1) * blockSize)])
            let pBlock = xor(offset, aesDecryptBlock(xor(cBlock, offset), key: key))
            plaintext.append(contentsOf: pBlock)
            checksum = xor(checksum, pBlock)
        }

        let remainder = Array(body[(fullBlockCount * blockSize)...])
        let tag: [UInt8]
        if remainder.isEmpty {
            tag = xor(
                aesEncryptBlock(xor(xor(checksum, offset), lTable.lDollar), key: key),
                hash(key: key, lTable: lTable, associatedData: associatedData)
            )
        } else {
            let offsetStar = xor(offset, lTable.lStar)
            let pad = aesEncryptBlock(offsetStar, key: key)
            let pStar = xor(remainder, Array(pad.prefix(remainder.count)))
            plaintext.append(contentsOf: pStar)
            checksum = xor(checksum, pad128(pStar))
            tag = xor(
                aesEncryptBlock(xor(xor(checksum, offsetStar), lTable.lDollar), key: key),
                hash(key: key, lTable: lTable, associatedData: associatedData)
            )
        }

        guard constantTimeEqual(tag, providedTag) else {
            throw AuthenticationFailure()
        }
        return plaintext
    }

    // MARK: - Key-dependent L table (RFC 7253 §4.1: L_*, L_$, L_0, L_1, ...)

    private final class LTable {
        let lStar: [UInt8]
        let lDollar: [UInt8]
        private var cache: [[UInt8]]

        init(key: [UInt8]) {
            let lStar = aesEncryptBlock([UInt8](repeating: 0, count: blockSize), key: key)
            let lDollar = MoshOCB.double(lStar)
            self.lStar = lStar
            self.lDollar = lDollar
            self.cache = [MoshOCB.double(lDollar)] // L_0
        }

        func l(for index: Int) -> [UInt8] {
            while cache.count <= index {
                cache.append(MoshOCB.double(cache[cache.count - 1]))
            }
            return cache[index]
        }
    }

    /// RFC 7253 §4.1 HASH(K, A): authenticates associated data. Mosh always
    /// calls with empty associated data (for which HASH trivially returns
    /// all zero bits), but this is implemented in full so it can be checked
    /// against every published test vector, not just the empty-AD subset.
    private static func hash(key: [UInt8], lTable: LTable, associatedData: [UInt8]) -> [UInt8] {
        guard !associatedData.isEmpty else {
            return [UInt8](repeating: 0, count: blockSize)
        }

        var offset = [UInt8](repeating: 0, count: blockSize)
        var sum = [UInt8](repeating: 0, count: blockSize)
        let fullBlockCount = associatedData.count / blockSize
        for i in 0..<fullBlockCount {
            offset = xor(offset, lTable.l(for: (i + 1).trailingZeroBitCount))
            let aBlock = Array(associatedData[(i * blockSize)..<((i + 1) * blockSize)])
            sum = xor(sum, aesEncryptBlock(xor(aBlock, offset), key: key))
        }

        let remainder = Array(associatedData[(fullBlockCount * blockSize)...])
        if !remainder.isEmpty {
            let offsetStar = xor(offset, lTable.lStar)
            sum = xor(sum, aesEncryptBlock(xor(pad128(remainder), offsetStar), key: key))
        }
        return sum
    }

    /// RFC 7253's "P_* || 1 || zeros(127-bitlen(P_*))" padding, specialized
    /// to byte-aligned inputs (the only kind this app ever produces): a
    /// single 0x80 byte (the "1" bit followed by zero bits) then zero bytes
    /// out to a full 16-byte block.
    private static func pad128(_ partialBlock: [UInt8]) -> [UInt8] {
        precondition(partialBlock.count < blockSize)
        var padded = partialBlock
        padded.append(0x80)
        padded.append(contentsOf: [UInt8](repeating: 0, count: blockSize - padded.count))
        return padded
    }

    /// RFC 7253 §4.2 nonce-dependent setup (Ktop/Stretch/bottom), specialized
    /// to TAGLEN==128 (mosh's only tag length): with TAGLEN mod 128 == 0,
    /// the "num2str(TAGLEN mod 128,7) || zeros(120-bitlen(N)) || 1 || N"
    /// construction collapses to a 16-byte buffer of zeros with a single
    /// 1 bit placed immediately before where `nonce` is copied in.
    private static func initialOffset(key: [UInt8], nonce: [UInt8]) -> [UInt8] {
        var paddedNonce = [UInt8](repeating: 0, count: blockSize)
        paddedNonce[blockSize - 1 - nonce.count] = 0x01
        for (i, byte) in nonce.enumerated() {
            paddedNonce[blockSize - nonce.count + i] = byte
        }

        let bottom = Int(paddedNonce[blockSize - 1] & 0x3F)
        var ktopInput = paddedNonce
        ktopInput[blockSize - 1] &= 0xC0
        let ktop = aesEncryptBlock(ktopInput, key: key)

        var stretch = ktop
        for i in 0..<8 {
            stretch.append(ktop[i] ^ ktop[i + 1])
        }

        let byteShift = bottom / 8
        let bitShift = bottom % 8
        guard bitShift != 0 else {
            return Array(stretch[byteShift..<(byteShift + blockSize)])
        }
        var offset = [UInt8](repeating: 0, count: blockSize)
        for i in 0..<blockSize {
            offset[i] = (stretch[byteShift + i] << bitShift) | (stretch[byteShift + i + 1] >> (8 - bitShift))
        }
        return offset
    }

    /// RFC 7253 §2 double(): multiplication by x in GF(2^128) using the
    /// polynomial x^128 + x^7 + x^2 + x + 1 (0x87), applied to a big-endian
    /// 128-bit string (S[1] is the MSB of byte 0).
    private static func double(_ block: [UInt8]) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: blockSize)
        for i in 0..<blockSize {
            let carryIn: UInt8 = (i + 1 < blockSize) ? (block[i + 1] >> 7) : 0
            result[i] = (block[i] << 1) | carryIn
        }
        if (block[0] & 0x80) != 0 {
            result[blockSize - 1] ^= 0x87
        }
        return result
    }

    private static func xor(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
        precondition(a.count == b.count)
        var result = [UInt8](repeating: 0, count: a.count)
        for i in 0..<a.count {
            result[i] = a[i] ^ b[i]
        }
        return result
    }

    private static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count {
            diff |= a[i] ^ b[i]
        }
        return diff == 0
    }

    // MARK: - Single-block AES-128 (the OCB "ENCIPHER"/"DECIPHER" primitive)

    private static func aesEncryptBlock(_ block: [UInt8], key: [UInt8]) -> [UInt8] {
        cryptBlock(block, key: key, operation: CCOperation(kCCEncrypt))
    }

    private static func aesDecryptBlock(_ block: [UInt8], key: [UInt8]) -> [UInt8] {
        cryptBlock(block, key: key, operation: CCOperation(kCCDecrypt))
    }

    private static func cryptBlock(_ block: [UInt8], key: [UInt8], operation: CCOperation) -> [UInt8] {
        precondition(block.count == blockSize)
        var output = [UInt8](repeating: 0, count: blockSize)
        var moved = 0
        let status = CCCrypt(
            operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
            key, key.count, nil,
            block, block.count,
            &output, output.count, &moved
        )
        precondition(status == kCCSuccess && moved == blockSize, "AES single-block operation failed unexpectedly")
        return output
    }
}
