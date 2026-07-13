import Foundation
import CryptoKit
import NIO
import NIOSSH

/// Computes host key fingerprints in the standard OpenSSH
/// `SHA256:base64(no padding)` form, e.g. `SHA256:4kzfF...`.
enum HostKeyFingerprint {
    static func sha256(of publicKey: NIOSSHPublicKey) -> String {
        var buffer = ByteBuffer()
        publicKey.write(to: &buffer)
        let digest = SHA256.hash(data: Data(buffer.readableBytesView))
        let base64 = Data(digest).base64EncodedString()
        let unpadded = base64.replacingOccurrences(of: "=", with: "")
        return "SHA256:\(unpadded)"
    }
}
