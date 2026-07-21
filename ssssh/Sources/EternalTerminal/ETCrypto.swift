import Foundation

/// Shared building block for `Salsa20Core`'s full stream-cipher core and
/// `HSalsa20Core`'s subkey-derivation core -- both run the exact same
/// 20-round (10 double-round) permutation network, differing only in
/// whether the pre-permutation state is added back into the output and
/// which output words survive. Mirrored line-for-line from libsodium's
/// `crypto_core_salsa20`/`crypto_core_hsalsa20` reference C
/// (`crypto_core/salsa/ref/core_salsa_ref.c`,
/// `crypto_core/hsalsa20/ref2/core_hsalsa20_ref2.c`) so the two can't drift
/// apart from each other or from upstream.
enum SalsaPermutation {
    static let sigma: (UInt32, UInt32, UInt32, UInt32) = (0x6170_7865, 0x3320_646e, 0x7962_2d32, 0x6b20_6574)

    @inline(__always) static func rotl(_ v: UInt32, _ n: UInt32) -> UInt32 { (v << n) | (v >> (32 - n)) }

    @inline(__always) static func load32LE(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
    }

    static func append32LE(_ v: UInt32, to out: inout [UInt8]) {
        out.append(UInt8(v & 0xff))
        out.append(UInt8((v >> 8) & 0xff))
        out.append(UInt8((v >> 16) & 0xff))
        out.append(UInt8((v >> 24) & 0xff))
    }

    /// `input` is the 16-byte block-position/nonce field, `key` is 32
    /// bytes. Returns the pre-permutation state (needed for Salsa20's
    /// add-back) and the state after the 20-round permutation.
    static func run(input: [UInt8], key: [UInt8]) -> (initial: [UInt32], permuted: [UInt32]) {
        precondition(input.count == 16 && key.count == 32)
        var w = [UInt32](repeating: 0, count: 16)
        w[0] = sigma.0; w[5] = sigma.1; w[10] = sigma.2; w[15] = sigma.3
        w[1] = load32LE(key, 0); w[2] = load32LE(key, 4); w[3] = load32LE(key, 8); w[4] = load32LE(key, 12)
        w[11] = load32LE(key, 16); w[12] = load32LE(key, 20); w[13] = load32LE(key, 24); w[14] = load32LE(key, 28)
        w[6] = load32LE(input, 0); w[7] = load32LE(input, 4); w[8] = load32LE(input, 8); w[9] = load32LE(input, 12)

        var x0 = w[0], x1 = w[1], x2 = w[2], x3 = w[3]
        var x4 = w[4], x5 = w[5], x6 = w[6], x7 = w[7]
        var x8 = w[8], x9 = w[9], x10 = w[10], x11 = w[11]
        var x12 = w[12], x13 = w[13], x14 = w[14], x15 = w[15]

        for _ in 0..<10 {
            x4 ^= rotl(x0 &+ x12, 7)
            x8 ^= rotl(x4 &+ x0, 9)
            x12 ^= rotl(x8 &+ x4, 13)
            x0 ^= rotl(x12 &+ x8, 18)
            x9 ^= rotl(x5 &+ x1, 7)
            x13 ^= rotl(x9 &+ x5, 9)
            x1 ^= rotl(x13 &+ x9, 13)
            x5 ^= rotl(x1 &+ x13, 18)
            x14 ^= rotl(x10 &+ x6, 7)
            x2 ^= rotl(x14 &+ x10, 9)
            x6 ^= rotl(x2 &+ x14, 13)
            x10 ^= rotl(x6 &+ x2, 18)
            x3 ^= rotl(x15 &+ x11, 7)
            x7 ^= rotl(x3 &+ x15, 9)
            x11 ^= rotl(x7 &+ x3, 13)
            x15 ^= rotl(x11 &+ x7, 18)
            x1 ^= rotl(x0 &+ x3, 7)
            x2 ^= rotl(x1 &+ x0, 9)
            x3 ^= rotl(x2 &+ x1, 13)
            x0 ^= rotl(x3 &+ x2, 18)
            x6 ^= rotl(x5 &+ x4, 7)
            x7 ^= rotl(x6 &+ x5, 9)
            x4 ^= rotl(x7 &+ x6, 13)
            x5 ^= rotl(x4 &+ x7, 18)
            x11 ^= rotl(x10 &+ x9, 7)
            x8 ^= rotl(x11 &+ x10, 9)
            x9 ^= rotl(x8 &+ x11, 13)
            x10 ^= rotl(x9 &+ x8, 18)
            x12 ^= rotl(x15 &+ x14, 7)
            x13 ^= rotl(x12 &+ x15, 9)
            x14 ^= rotl(x13 &+ x12, 13)
            x15 ^= rotl(x14 &+ x13, 18)
        }

        return (w, [x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11, x12, x13, x14, x15])
    }
}

/// The full Salsa20 stream-cipher core: `SalsaPermutation`'s 20-round
/// network with the pre-permutation state added back in, producing a
/// 64-byte keystream block per call. Only used here as `XSalsa20`'s inner
/// block generator, one block-counter position at a time.
enum Salsa20Core {
    static func block(input: [UInt8], key: [UInt8]) -> [UInt8] {
        let (initial, permuted) = SalsaPermutation.run(input: input, key: key)
        var out = [UInt8]()
        out.reserveCapacity(64)
        for i in 0..<16 {
            SalsaPermutation.append32LE(permuted[i] &+ initial[i], to: &out)
        }
        return out
    }
}

/// `crypto_core_hsalsa20`: same permutation, no add-back, and only 8 of
/// the 16 output words survive, in this specific reordering -- used
/// solely to derive XSalsa20's 32-byte subkey from the first 16 bytes of
/// its 24-byte nonce.
enum HSalsa20Core {
    static func block(input: [UInt8], key: [UInt8]) -> [UInt8] {
        let (_, x) = SalsaPermutation.run(input: input, key: key)
        var out = [UInt8]()
        out.reserveCapacity(32)
        for i in [0, 5, 10, 15, 6, 7, 8, 9] {
            SalsaPermutation.append32LE(x[i], to: &out)
        }
        return out
    }
}

/// `crypto_stream_xsalsa20`/`crypto_stream_xsalsa20_xor_ic`: derives a
/// subkey via `HSalsa20Core` from the nonce's first 16 bytes, then
/// generates Salsa20 keystream using that subkey and the nonce's last 8
/// bytes as the classic 8-byte-nonce-plus-8-byte-little-endian-counter
/// input, starting at block counter `counter`.
enum XSalsa20 {
    static func keystream(nonce: [UInt8], key: [UInt8], counter: UInt64 = 0, length: Int) -> [UInt8] {
        precondition(nonce.count == 24 && key.count == 32)
        let subkey = HSalsa20Core.block(input: Array(nonce[0..<16]), key: key)
        var blockInput = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 { blockInput[i] = nonce[16 + i] }

        var out = [UInt8]()
        out.reserveCapacity(length)
        var blockCounter = counter
        while out.count < length {
            for i in 0..<8 {
                blockInput[8 + i] = UInt8((blockCounter >> (8 * UInt64(i))) & 0xff)
            }
            let block = Salsa20Core.block(input: blockInput, key: subkey)
            let remaining = length - out.count
            out.append(contentsOf: block.prefix(min(64, remaining)))
            blockCounter &+= 1
        }
        return out
    }

    static func xor(message: [UInt8], nonce: [UInt8], key: [UInt8], counter: UInt64 = 0) -> [UInt8] {
        let stream = keystream(nonce: nonce, key: key, counter: counter, length: message.count)
        var out = [UInt8](repeating: 0, count: message.count)
        for i in 0..<message.count { out[i] = message[i] ^ stream[i] }
        return out
    }
}

/// Ported line-for-line from the canonical public-domain
/// `poly1305-donna-32.h` reference (D. Bernstein / Andrew Moon,
/// `floodyberry/poly1305-donna`), substituting `UInt32`/`UInt64` for
/// `unsigned long`/`unsigned long long` -- this is the exact algorithm
/// libsodium itself uses (`crypto_onetimeauth/poly1305/donna`). Verified
/// against libsodium's own published test vectors, not just internal
/// round-trip consistency -- see `ETCryptoTests`.
enum Poly1305 {
    static func authenticate(message: [UInt8], key: [UInt8]) -> [UInt8] {
        precondition(key.count == 32)

        func u8to32(_ b: [UInt8], _ o: Int) -> UInt32 {
            UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
        }

        let r0 = u8to32(key, 0) & 0x3ff_ffff
        let r1 = (u8to32(key, 3) >> 2) & 0x3ff_ff03
        let r2 = (u8to32(key, 6) >> 4) & 0x3ff_c0ff
        let r3 = (u8to32(key, 9) >> 6) & 0x3f0_3fff
        let r4 = (u8to32(key, 12) >> 8) & 0x00f_ffff

        let s1 = r1 &* 5, s2 = r2 &* 5, s3 = r3 &* 5, s4 = r4 &* 5

        var h0: UInt32 = 0, h1: UInt32 = 0, h2: UInt32 = 0, h3: UInt32 = 0, h4: UInt32 = 0

        func processBlock(_ m: [UInt8], _ offset: Int, hibit: UInt32) {
            h0 &+= u8to32(m, offset) & 0x3ff_ffff
            h1 &+= (u8to32(m, offset + 3) >> 2) & 0x3ff_ffff
            h2 &+= (u8to32(m, offset + 6) >> 4) & 0x3ff_ffff
            h3 &+= (u8to32(m, offset + 9) >> 6) & 0x3ff_ffff
            h4 &+= (u8to32(m, offset + 12) >> 8) | hibit

            let d0 = UInt64(h0) &* UInt64(r0) &+ UInt64(h1) &* UInt64(s4) &+ UInt64(h2) &* UInt64(s3)
                &+ UInt64(h3) &* UInt64(s2) &+ UInt64(h4) &* UInt64(s1)
            let d1 = UInt64(h0) &* UInt64(r1) &+ UInt64(h1) &* UInt64(r0) &+ UInt64(h2) &* UInt64(s4)
                &+ UInt64(h3) &* UInt64(s3) &+ UInt64(h4) &* UInt64(s2)
            let d2 = UInt64(h0) &* UInt64(r2) &+ UInt64(h1) &* UInt64(r1) &+ UInt64(h2) &* UInt64(r0)
                &+ UInt64(h3) &* UInt64(s4) &+ UInt64(h4) &* UInt64(s3)
            let d3 = UInt64(h0) &* UInt64(r3) &+ UInt64(h1) &* UInt64(r2) &+ UInt64(h2) &* UInt64(r1)
                &+ UInt64(h3) &* UInt64(r0) &+ UInt64(h4) &* UInt64(s4)
            let d4 = UInt64(h0) &* UInt64(r4) &+ UInt64(h1) &* UInt64(r3) &+ UInt64(h2) &* UInt64(r2)
                &+ UInt64(h3) &* UInt64(r1) &+ UInt64(h4) &* UInt64(r0)

            var dd1 = d1, dd2 = d2, dd3 = d3, dd4 = d4
            var c: UInt64

            c = d0 >> 26; h0 = UInt32(d0 & 0x3ff_ffff)
            dd1 &+= c; c = dd1 >> 26; h1 = UInt32(dd1 & 0x3ff_ffff)
            dd2 &+= c; c = dd2 >> 26; h2 = UInt32(dd2 & 0x3ff_ffff)
            dd3 &+= c; c = dd3 >> 26; h3 = UInt32(dd3 & 0x3ff_ffff)
            dd4 &+= c; c = dd4 >> 26; h4 = UInt32(dd4 & 0x3ff_ffff)
            h0 &+= UInt32(c) &* 5
            let c2 = h0 >> 26
            h0 &= 0x3ff_ffff
            h1 &+= c2
        }

        var offset = 0
        while offset + 16 <= message.count {
            processBlock(message, offset, hibit: 1 << 24)
            offset += 16
        }
        let leftover = message.count - offset
        if leftover > 0 {
            var buf = [UInt8](repeating: 0, count: 16)
            for i in 0..<leftover { buf[i] = message[offset + i] }
            buf[leftover] = 1
            processBlock(buf, 0, hibit: 0)
        }

        // fully carry h
        var c: UInt32
        c = h1 >> 26; h1 &= 0x3ff_ffff
        h2 &+= c; c = h2 >> 26; h2 &= 0x3ff_ffff
        h3 &+= c; c = h3 >> 26; h3 &= 0x3ff_ffff
        h4 &+= c; c = h4 >> 26; h4 &= 0x3ff_ffff
        h0 &+= c &* 5; c = h0 >> 26; h0 &= 0x3ff_ffff
        h1 &+= c

        // compute h + -p, then select h if h < p, or h + -p if h >= p
        var g0 = h0 &+ 5; c = g0 >> 26; g0 &= 0x3ff_ffff
        var g1 = h1 &+ c; c = g1 >> 26; g1 &= 0x3ff_ffff
        var g2 = h2 &+ c; c = g2 >> 26; g2 &= 0x3ff_ffff
        var g3 = h3 &+ c; c = g3 >> 26; g3 &= 0x3ff_ffff
        let g4 = h4 &+ c &- (1 << 26)

        let mask: UInt32 = (g4 >> 31) &- 1
        g0 &= mask; g1 &= mask; g2 &= mask; g3 &= mask
        let g4masked = g4 & mask
        let invMask = ~mask
        h0 = (h0 & invMask) | g0
        h1 = (h1 & invMask) | g1
        h2 = (h2 & invMask) | g2
        h3 = (h3 & invMask) | g3
        h4 = (h4 & invMask) | g4masked

        // h mod 2^128, repacked into 4 x 32-bit words
        let o0 = h0 | (h1 << 26)
        let o1 = (h1 >> 6) | (h2 << 20)
        let o2 = (h2 >> 12) | (h3 << 14)
        let o3 = (h3 >> 18) | (h4 << 8)

        let pad0 = u8to32(key, 16), pad1 = u8to32(key, 20), pad2 = u8to32(key, 24), pad3 = u8to32(key, 28)

        var f: UInt64 = UInt64(o0) &+ UInt64(pad0)
        let m0 = UInt32(truncatingIfNeeded: f)
        f = UInt64(o1) &+ UInt64(pad1) &+ (f >> 32)
        let m1 = UInt32(truncatingIfNeeded: f)
        f = UInt64(o2) &+ UInt64(pad2) &+ (f >> 32)
        let m2 = UInt32(truncatingIfNeeded: f)
        f = UInt64(o3) &+ UInt64(pad3) &+ (f >> 32)
        let m3 = UInt32(truncatingIfNeeded: f)

        var out = [UInt8](repeating: 0, count: 16)
        func store(_ v: UInt32, _ o: Int) {
            out[o] = UInt8(v & 0xff)
            out[o + 1] = UInt8((v >> 8) & 0xff)
            out[o + 2] = UInt8((v >> 16) & 0xff)
            out[o + 3] = UInt8((v >> 24) & 0xff)
        }
        store(m0, 0); store(m1, 4); store(m2, 8); store(m3, 12)
        return out
    }
}

/// XSalsa20-Poly1305 in the exact shape `crypto_secretbox_easy`/
/// `_open_easy` use (see `crypto_secretbox/crypto_secretbox_easy.c`
/// upstream): a 32-byte-key, 24-byte-nonce AEAD with **no associated
/// data**, wire layout `MAC(16) || ciphertext(mlen)` -- MAC **prepended**,
/// not appended (a correction to this repo's own CLAUDE.md notes; see
/// there for detail). Implemented as the mathematically equivalent
/// simplified form: generate `32 + mlen` bytes of XSalsa20 keystream from
/// block counter 0, use the first 32 bytes as the Poly1305 one-time key,
/// XOR the message against the remaining `mlen` bytes, then MAC the
/// ciphertext. This is provably identical to `crypto_secretbox_detached`'s
/// 64-byte-buffer-reuse implementation (verified against its real output,
/// not just derived) -- the buffer-reuse trick there is a performance
/// detail of the reference C, not part of the construction itself.
enum ETSecretBox {
    static func seal(message: [UInt8], nonce: [UInt8], key: [UInt8]) -> [UInt8] {
        let stream = XSalsa20.keystream(nonce: nonce, key: key, counter: 0, length: 32 + message.count)
        let polyKey = Array(stream[0..<32])
        var ciphertext = [UInt8](repeating: 0, count: message.count)
        for i in 0..<message.count { ciphertext[i] = message[i] ^ stream[32 + i] }
        let mac = Poly1305.authenticate(message: ciphertext, key: polyKey)
        return mac + ciphertext
    }

    enum OpenError: Error { case authenticationFailed }

    static func open(sealed: [UInt8], nonce: [UInt8], key: [UInt8]) throws -> [UInt8] {
        guard sealed.count >= 16 else { throw OpenError.authenticationFailed }
        let mac = Array(sealed[0..<16])
        let ciphertext = Array(sealed[16...])
        let stream = XSalsa20.keystream(nonce: nonce, key: key, counter: 0, length: 32 + ciphertext.count)
        let polyKey = Array(stream[0..<32])
        let expectedMac = Poly1305.authenticate(message: ciphertext, key: polyKey)
        guard constantTimeEqual(mac, expectedMac) else { throw OpenError.authenticationFailed }
        var message = [UInt8](repeating: 0, count: ciphertext.count)
        for i in 0..<ciphertext.count { message[i] = ciphertext[i] ^ stream[32 + i] }
        return message
    }

    private static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }
}

/// Mirrors `CryptoHandler` (`src/base/CryptoHandler.cpp`) exactly: a
/// stateful wrapper holding a 24-byte nonce and 32-byte key, incrementing
/// the nonce by one -- a little-endian, whole-24-byte counter with carry,
/// starting at byte 0 -- *before* every single encrypt/decrypt call,
/// including the first (so message #1 uses seed+1, never the raw seed).
/// The nonce is seeded to all zero except its *last* byte, set to
/// `directionByte` (`CLIENT_SERVER_NONCE_MSB` = 0, `SERVER_CLIENT_NONCE_MSB`
/// = 1 upstream, `src/base/Headers.hpp`) -- each direction needs its own
/// independent instance sharing the same key, and a writer/reader pair
/// stay in sync only because both increment in the same lockstep, once per
/// message, with no skipped or replayed nonce ever tolerated.
final class ETCryptoStream {
    private var nonce: [UInt8]
    private let key: [UInt8]

    init(key: [UInt8], directionByte: UInt8) {
        precondition(key.count == 32)
        self.key = key
        var n = [UInt8](repeating: 0, count: 24)
        n[23] = directionByte
        self.nonce = n
    }

    private func incrementNonce() {
        for i in 0..<24 {
            nonce[i] = nonce[i] &+ 1
            if nonce[i] != 0 { break }
        }
    }

    func encrypt(_ message: [UInt8]) -> [UInt8] {
        incrementNonce()
        return ETSecretBox.seal(message: message, nonce: nonce, key: key)
    }

    func decrypt(_ sealed: [UInt8]) throws -> [UInt8] {
        incrementNonce()
        return try ETSecretBox.open(sealed: sealed, nonce: nonce, key: key)
    }
}
