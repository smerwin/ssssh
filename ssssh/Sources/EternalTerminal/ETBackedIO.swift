import Foundation

/// Mirrors `BackedWriter` (`src/base/BackedWriter.cpp`): encrypts and backs
/// up every packet before attempting to send it, so a reconnect can replay
/// exactly what the peer is missing. Unlike the C++ (which owns the socket
/// and performs the write inline, retrying synchronously), this only
/// produces the framed bytes a caller should send -- actual `NWConnection`
/// I/O belongs to the future `ETTransport`, matching this app's existing
/// pattern of keeping protocol-state logic testable without a live socket.
final class ETBackedWriter {
    /// Matches `BackedWriter::MAX_BACKUP_BYTES` (64 MB) -- trimmed only
    /// while connected; nothing is ever evicted while disconnected; see
    /// `disconnectBufferBytes` for that separate cap.
    static let maxBackupBytes: Int64 = 64 * 1024 * 1024
    /// Matches `BackedWriter::DISCONNECT_BUFFER_BYTES` (64 MB) -- the
    /// separate cap on how much can be buffered *since* the socket was
    /// lost, past which `write` reports `.skipped` instead of buffering
    /// further.
    static let disconnectBufferBytes: Int64 = 64 * 1024 * 1024

    enum WriteResult: Equatable {
        /// No socket, and the disconnect buffer is already full -- matches
        /// `BackedWriterWriteState::SKIPPED`.
        case skipped
        /// No socket, but the packet was backed up for later recovery --
        /// matches `BUFFERED_ONLY`. Callers should treat this as success:
        /// the data isn't lost, only deferred.
        case bufferedOnly
        /// Connected -- these are the framed bytes (`ETPacketStreamReader`
        /// framing) to send on the live socket. Matches `SUCCESS`; this
        /// type has no equivalent of `WROTE_WITH_FAILURE` since it doesn't
        /// perform the write itself -- a caller whose actual socket write
        /// fails should call `invalidateSocket()` and let the backup buffer
        /// (already updated before this returns) handle recovery.
        case ready(bytes: [UInt8])
    }

    enum RecoverError: Error, Equatable {
        /// Matches `BackedWriter::recover`'s `STFATAL` for
        /// `messagesToRecover < 0` -- a peer claiming to have already seen
        /// more packets than were ever sent, a hard protocol-invariant
        /// violation there (process abort). Modeled here as a catchable
        /// error instead: crashing the whole app is not appropriate client
        /// behavior for a network protocol violation from a peer: the
        /// caller should tear down and refuse to resume this connection.
        case peerAheadOfSelf
        /// Matches `BackedWriter::recover`'s
        /// `runtime_error("Client is too far behind server.")` -- the
        /// requested range extends past what's still in the backup buffer
        /// (older entries were trimmed by `maxBackupBytes` while
        /// connected). Recoverable: this specific reconnect attempt should
        /// be abandoned and retried, not fatal to the whole session --
        /// mirrors mosh's own self-healing "let the next tick redeliver"
        /// philosophy (see CLAUDE.md's Mosh section).
        case tooFarBehind
        /// Matches `recover`'s own guard against being called while a
        /// socket is still attached.
        case stillConnected
    }

    private let cryptoStream: ETCryptoStream
    private var connected: Bool
    /// Newest-first, matching `backupBuffer.push_front` -- `recover` walks
    /// from the front (newest) and reverses before returning, exactly as
    /// the C++ does.
    private var backupBuffer: [ETPacket] = []
    private var backupSize: Int64 = 0
    private var disconnectedBytes: Int64 = 0
    private(set) var sequenceNumber: Int64 = 0

    init(cryptoStream: ETCryptoStream, connected: Bool) {
        self.cryptoStream = cryptoStream
        self.connected = connected
    }

    func hasBufferCapacity(_ bytes: Int64) -> Bool {
        connected || disconnectedBytes + bytes <= Self.disconnectBufferBytes
    }

    /// Encrypts, backs up, and (if connected) frames `packet` for sending.
    /// Mirrors `BackedWriter::write`'s exact order of operations,
    /// including a real quirk worth preserving rather than "fixing": the
    /// `.skipped` capacity check uses the packet's *pre-encryption* length
    /// (`packet.length()`, called before `packet.encrypt(...)` in the
    /// C++), while `disconnectedBytes`/`backupSize` accumulate the
    /// *post-encryption* length (16 bytes larger, from `ETSecretBox`'s
    /// MAC) -- so the real disconnect buffer holds very slightly less than
    /// `disconnectBufferBytes` worth of plaintext, not exactly that much.
    @discardableResult
    func write(_ packet: ETPacket) -> WriteResult {
        let preEncryptLength = Int64(2 + packet.payload.count)
        if !connected && disconnectedBytes + preEncryptLength > Self.disconnectBufferBytes {
            return .skipped
        }

        var encrypted = packet
        encrypted.payload = cryptoStream.encrypt(packet.payload)
        encrypted.encrypted = true

        backupBuffer.insert(encrypted, at: 0)
        let postEncryptLength = Int64(2 + encrypted.payload.count)
        backupSize += postEncryptLength
        sequenceNumber += 1

        while connected && backupSize > Self.maxBackupBytes {
            backupSize -= Int64(2 + backupBuffer.removeLast().payload.count)
        }

        if !connected {
            disconnectedBytes += postEncryptLength
            return .bufferedOnly
        }

        return .ready(bytes: ETPacketStreamReader.frame(encrypted))
    }

    /// Returns the framed, already-encrypted bytes of every packet sent
    /// since `lastValidSequenceNumber`, oldest first, ready to replay
    /// verbatim -- no re-encryption, matching the real client's own
    /// "resend exact bytes already sent" resume model (see CLAUDE.md's
    /// "Resumption/reconnect protocol" note on why this needs none of
    /// Mosh's framebuffer-equivalence-range tracking). Must only be called
    /// while disconnected, matching `BackedWriter::recover`.
    func recover(lastValidSequenceNumber: Int64) throws -> [[UInt8]] {
        guard !connected else { throw RecoverError.stillConnected }
        let messagesToRecover = sequenceNumber - lastValidSequenceNumber
        guard messagesToRecover >= 0 else { throw RecoverError.peerAheadOfSelf }
        guard messagesToRecover > 0 else { return [] }
        guard messagesToRecover <= backupBuffer.count else { throw RecoverError.tooFarBehind }

        let newestFirst = backupBuffer[0..<Int(messagesToRecover)]
        return newestFirst.reversed().map { $0.serialize() }
    }

    /// Points the writer at a (newly reconnected) live socket and resets
    /// disconnect accounting -- matches `BackedWriter::revive`.
    func revive(connected: Bool) {
        self.connected = connected
        disconnectedBytes = 0
    }
}

/// Mirrors `BackedReader` (`src/base/BackedReader.cpp`): decrypts packets
/// and tracks a sequence number of how many have been consumed, with a
/// replay queue that must be fully drained before resuming live reads.
/// Same "produces/consumes plain data, doesn't own the socket" split from
/// the C++ as `ETBackedWriter`.
final class ETBackedReader {
    private let cryptoStream: ETCryptoStream
    private var localBuffer: [[UInt8]] = []
    private(set) var sequenceNumber: Int64 = 0

    init(cryptoStream: ETCryptoStream) {
        self.cryptoStream = cryptoStream
    }

    var hasBufferedReplayData: Bool { !localBuffer.isEmpty }

    /// Queues serialized (still-encrypted) packets for replay and credits
    /// `sequenceNumber` for all of them *immediately* -- matching
    /// `BackedReader::revive`'s `sequenceNumber += newLocalEntries.size()`,
    /// which happens once, up front, not incrementally as each is later
    /// drained via `nextReplayPacket()`. These represent packets the peer
    /// already sent and this side is now catching up on, not fresh
    /// arrivals -- `constructPartialMessage`'s per-packet increment is only
    /// for genuinely new reads off the live socket (`consumeLivePacket`).
    func revive(replayPackets: [[UInt8]]) {
        localBuffer.append(contentsOf: replayPackets)
        sequenceNumber += Int64(replayPackets.count)
    }

    /// Drains and decrypts the next queued replay packet, if any. Callers
    /// must fully drain this (until it returns `nil`) before reading from
    /// the live socket, matching `BackedReader::read`'s own ordering
    /// (`localBuffer` always checked, and served, before ever touching the
    /// socket).
    func nextReplayPacket() throws -> ETPacket? {
        guard !localBuffer.isEmpty else { return nil }
        let bytes = localBuffer.removeFirst()
        var packet = try ETPacket.parse(bytes)
        packet.payload = try cryptoStream.decrypt(packet.payload)
        packet.encrypted = false
        return packet
    }

    /// Decrypts a packet just read from the live socket and increments
    /// `sequenceNumber` by one -- matches `constructPartialMessage`.
    func consumeLivePacket(_ packet: ETPacket) throws -> ETPacket {
        var result = packet
        result.payload = try cryptoStream.decrypt(packet.payload)
        result.encrypted = false
        sequenceNumber += 1
        return result
    }
}
