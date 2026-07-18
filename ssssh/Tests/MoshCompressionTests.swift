import Foundation
import Testing
@testable import ssssh

struct MoshCompressionTests {
    @Test("Round-trips arbitrary data")
    func roundTrips() throws {
        let original = Array("the quick brown fox jumps over the lazy dog, 0123456789, and some \u{0000}\u{0001} bytes".utf8)
        let compressed = try MoshCompression.compress(original)
        let decompressed = try MoshCompression.uncompress(compressed)
        #expect(decompressed == original)
    }

    @Test("Round-trips empty input")
    func roundTripsEmpty() throws {
        let compressed = try MoshCompression.compress([])
        let decompressed = try MoshCompression.uncompress(compressed)
        #expect(decompressed == [])
    }

    @Test("Produces byte-identical output to Python's zlib.compress (same underlying library/format)")
    func matchesReferenceZlibOutput() throws {
        let input = Array("hello mosh, this is a test payload for zlib compatibility checking 1234567890".utf8)
        let expectedCompressedHex = "789c0dc2cb1180200c05c0565e011efc7fca09889231184672c1ea7567631051242db181452ef8132c1443a62a4a3b0e7df00a3b784d998c1d0b5b858fc15f7c9fe8fa619ce665ddda0f3e311ab2"
        let expected = hex(expectedCompressedHex)
        let compressed = try MoshCompression.compress(input)
        #expect(compressed == expected)
    }

    @Test("Decompresses a fixed reference zlib blob back to the expected plaintext")
    func decompressesReferenceBlob() throws {
        let compressedHex = "789c0dc2cb1180200c05c0565e011efc7fca09889231184672c1ea7567631051242db181452ef8132c1443a62a4a3b0e7df00a3b784d998c1d0b5b858fc15f7c9fe8fa619ce665ddda0f3e311ab2"
        let expected = Array("hello mosh, this is a test payload for zlib compatibility checking 1234567890".utf8)
        let decompressed = try MoshCompression.uncompress(hex(compressedHex))
        #expect(decompressed == expected)
    }

    @Test("Handles payloads larger than the initial size-hint buffer")
    func handlesLargePayloads() throws {
        let original = [UInt8](repeating: 0x41, count: 200_000) + Array("tail".utf8)
        let compressed = try MoshCompression.compress(original)
        let decompressed = try MoshCompression.uncompress(compressed, sizeHint: 16)
        #expect(decompressed == original)
    }

    private func hex(_ s: String) -> [UInt8] {
        var bytes = [UInt8]()
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            bytes.append(UInt8(String(chars[i...i + 1]), radix: 16)!)
            i += 2
        }
        return bytes
    }
}
