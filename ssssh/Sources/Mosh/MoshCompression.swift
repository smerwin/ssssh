import Foundation
import zlib

/// Wraps zlib's `compress`/`uncompress` (imported via `BridgingHeader.h`)
/// for Mosh's Instruction payloads, which are always zlib-compressed on
/// the wire (mosh's own `Network::Compressor` in `compressor.cc` is a
/// thin wrapper around these same two C functions with zlib's defaults).
/// Using the real system zlib makes this byte-for-byte compatible with a
/// real mosh-server/mosh-client, rather than merely "similar."
enum MoshCompression {
    struct CompressionFailure: Error {}

    static func compress(_ input: [UInt8]) throws -> [UInt8] {
        var destLen = uLongf(compressBound(uLong(input.count)))
        var dest = [UInt8](repeating: 0, count: Int(destLen))
        let status = dest.withUnsafeMutableBufferPointer { destPtr -> Int32 in
            input.withUnsafeBufferPointer { srcPtr in
                zlib.compress(destPtr.baseAddress, &destLen, srcPtr.baseAddress, uLong(input.count))
            }
        }
        guard status == Z_OK else { throw CompressionFailure() }
        return Array(dest.prefix(Int(destLen)))
    }

    /// `sizeHint` avoids a guaranteed-undersized first attempt for typical
    /// terminal-diff payloads; the loop below still handles anything
    /// larger correctly by doubling and retrying.
    static func uncompress(_ input: [UInt8], sizeHint: Int = 4096) throws -> [UInt8] {
        var capacity = max(sizeHint, input.count * 4, 256)
        while true {
            var destLen = uLongf(capacity)
            var dest = [UInt8](repeating: 0, count: capacity)
            let status = dest.withUnsafeMutableBufferPointer { destPtr -> Int32 in
                input.withUnsafeBufferPointer { srcPtr in
                    zlib.uncompress(destPtr.baseAddress, &destLen, srcPtr.baseAddress, uLong(input.count))
                }
            }
            switch status {
            case Z_OK:
                return Array(dest.prefix(Int(destLen)))
            case Z_BUF_ERROR where capacity < 64 * 1024 * 1024:
                capacity *= 2
            default:
                throw CompressionFailure()
            }
        }
    }
}
