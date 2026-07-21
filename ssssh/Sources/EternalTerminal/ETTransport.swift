import Foundation
import Network

/// A live Eternal Terminal session's TCP transport: connects to `etserver`,
/// performs the `ConnectRequest`/`ConnectResponse` handshake, sends the
/// required `InitialPayload`/waits for `InitialResponse`, then exchanges
/// ordinary `TerminalBuffer`/`TerminalInfo`/`KEEP_ALIVE` packets through
/// `ETBackedWriter`/`ETBackedReader`. The exact sequence and message shapes
/// are grounded directly in `ClientConnection::connect`
/// (`src/base/ClientConnection.cpp`) and `TerminalClient`'s constructor/
/// `run()` (`src/terminal/TerminalClient.cpp`), not assumed -- see
/// CLAUDE.md's Eternal Terminal section, particularly the note correcting
/// an earlier wrong assumption that `TerminalUserInfo`/`TermInit` were
/// part of this flow (they aren't; only the messages this type actually
/// sends/receives are).
///
/// Unlike `MoshTransport` (UDP, roaming via rebuilding the connection on
/// any network change), this is TCP: `NWConnection` itself handles ordinary
/// packet loss/retransmission, and ET's own resume protocol
/// (`ETBackedWriter`/`ETBackedReader`, see CLAUDE.md's "Resumption/
/// reconnect protocol") handles a full connection loss by reconnecting and
/// replaying exactly what the peer is missing -- no framebuffer-diff
/// modeling, no client-side prediction, both deliberately absent here for
/// the same reason CLAUDE.md's "Why native scrolling and tmux -CC work"
/// section describes ET as a "dumb pipe."
final class ETTransport: @unchecked Sendable {
    /// Decoded `TerminalBuffer` bytes, ready to feed to a terminal view --
    /// same shape as `SSHConnection.onOutput`/`MoshTransport.onOutput`.
    var onOutput: (([UInt8]) -> Void)?
    var onError: ((Error) -> Void)?
    /// Fires once, the first time the session is fully established --
    /// after `InitialResponse` reports no error -- or once again after
    /// each successful reconnect's recovery handshake completes.
    var onEstablished: (() -> Void)?

    enum TransportError: LocalizedError {
        case connectResponseRejected(status: ETConnectStatus?, message: String)
        case missingInitialResponse
        case initialResponseError(String)
        /// Matches the real client's `STFATAL` for an unrecognized packet
        /// header -- modeled as a reported, catchable error rather than a
        /// crash, same reasoning as `ETBackedWriter.RecoverError.peerAheadOfSelf`.
        case unknownPacketHeader(UInt8)
        case reconnectRejected(status: ETConnectStatus?, message: String)
        /// After `maxConsecutiveReconnectFailures` back-to-back rejected/
        /// failed reconnect attempts, same shape as `MoshTransportError
        /// .roamingGaveUp`.
        case reconnectGaveUp(reason: String)

        var errorDescription: String? {
            switch self {
            case .connectResponseRejected(let status, let message):
                return "Eternal Terminal connection rejected (\(String(describing: status)): \(message))"
            case .missingInitialResponse:
                return "Eternal Terminal server never sent an initial response"
            case .initialResponseError(let message):
                return "Eternal Terminal server rejected the session: \(message)"
            case .unknownPacketHeader(let header):
                return "Eternal Terminal server sent an unrecognized packet type: \(header)"
            case .reconnectRejected(let status, let message):
                return "Eternal Terminal reconnect rejected (\(String(describing: status)): \(message))"
            case .reconnectGaveUp(let reason):
                return "Eternal Terminal gave up reconnecting after \(ETTransport.maxConsecutiveReconnectFailures) attempts (\(reason))"
            }
        }
    }

    /// `PROTOCOL_VERSION` (`src/base/Headers.hpp`) as of this writing.
    private static let protocolVersion: Int32 = 6
    /// `MAX_CLIENT_KEEP_ALIVE_DURATION` (`src/base/Headers.hpp`), the real
    /// client's own default.
    private static let keepAliveInterval: TimeInterval = 5

    private enum Phase {
        /// Accumulating bytes for one `ETOneShotProto` message
        /// (`ConnectResponse` on first connect, `SequenceHeader` then
        /// `CatchupBuffer` on reconnect -- `oneShotStep` tracks which).
        case awaitingOneShot
        case live
    }
    private enum OneShotStep {
        case connectResponse
        case sequenceHeader
        case catchupBuffer
    }

    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private let id: String
    private let key: [UInt8]
    private var connection: NWConnection
    private let queue = DispatchQueue(label: "com.smerwin.ssssh.et-transport")

    private var phase: Phase = .awaitingOneShot
    private var oneShotStep: OneShotStep = .connectResponse
    private var oneShotBuffer: [UInt8] = []
    private var packetStreamReader = ETPacketStreamReader()

    private var reader: ETBackedReader!
    private var writer: ETBackedWriter!
    private var hasSignaledEstablishedOnce = false

    private var hasReportedFatalError = false
    private var isStopped = false
    private var keepAliveTimer: DispatchSourceTimer?
    private var waitingOnKeepAlive = false

    /// Counts consecutive failed *reconnect* attempts -- both an ordinary
    /// connection-level failure (`.failed` state, a send/receive error) and
    /// a rejected reconnect `ConnectResponse` (see `handleConnectResponse`)
    /// feed into this same counter. Reported live, against a real wifi/5G
    /// interface handoff: the very first reconnect attempt after the
    /// handoff got a `ConnectResponse` rejecting it with `invalidKey`
    /// ("Client is not registered") -- previously treated identically to a
    /// rejected *first* connect (immediately fatal, no retry at all). Real
    /// `etserver` deployment/timeout characteristics under a genuine
    /// interface change (as opposed to this repo's only verified scenario,
    /// an `iptables DROP` blackout that never changes the client's local
    /// address) haven't been characterized -- see CLAUDE.md's Eternal
    /// Terminal section -- so a rejection shortly after a handoff might be
    /// transient (the server catching up) or might be permanent. Retrying
    /// with backoff costs nothing in the permanent case (a few extra
    /// seconds before the same eventual failure) and recovers the session
    /// in the transient case, instead of always tearing down a session that
    /// might still be resumable.
    private var consecutiveReconnectFailures = 0
    /// Mirrors `MoshTransport.maxConsecutiveRebuildFailures` -- after this
    /// many back-to-back failures, stop retrying and report a hard failure
    /// via `onError` instead of retrying forever against a genuinely dead
    /// network or a permanently unrecognized client id.
    private static let maxConsecutiveReconnectFailures = 5
    /// Unlike `MoshTransport.rebuildBackoff` (paired with a periodic
    /// heartbeat/path-monitor drumbeat that keeps re-triggering rebuilds,
    /// so a plain gate-and-return works), `ETTransport` has no equivalent
    /// steady stream of external triggers while disconnected -- so the
    /// delay is scheduled directly (`queue.asyncAfter`) rather than gating
    /// on a `nextAllowedRebuildAttempt` timestamp. The very first attempt
    /// after any failure stays immediate (the common roaming case, same
    /// reasoning as Mosh's), then backs off exponentially, capped at 30s.
    static func reconnectBackoff(forFailureCount count: Int) -> TimeInterval {
        count <= 1 ? 0 : min(pow(2.0, Double(count - 1)), 30)
    }

    init(host: String, port: UInt16, id: String, passkeyBytes: [UInt8]) {
        self.host = .init(host)
        self.port = .init(rawValue: port)!
        self.id = id
        self.key = passkeyBytes
        self.connection = NWConnection(host: self.host, port: self.port, using: .tcp)
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.phase = .awaitingOneShot
            self.oneShotStep = .connectResponse
            self.armConnection(isReconnect: false)
            self.connection.start(queue: self.queue)
        }
    }

    func stop() {
        queue.sync {
            isStopped = true
            keepAliveTimer?.cancel()
            keepAliveTimer = nil
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
    }

    /// Sends local input as a `TerminalBuffer` packet.
    func send(_ bytes: [UInt8]) {
        queue.async { [weak self] in
            guard let self else { return }
            var tb = ETTerminalBuffer()
            tb.buffer = bytes
            self.sendPacket(header: .terminalBuffer, payload: tb.encode())
        }
    }

    /// Sends a PTY resize as a `TerminalInfo` packet. `id` is left empty,
    /// matching the real client -- confirmed by reading
    /// `PseudoTerminalConsole::getTerminalInfo` (`src/terminal/PseudoTerminalConsole.hpp`)
    /// directly: it never calls `TerminalInfo::set_id` at all, only
    /// row/column/width/height from `ioctl(TIOCGWINSZ)`.
    func resize(cols: Int32, rows: Int32, widthPixels: Int32 = 0, heightPixels: Int32 = 0) {
        queue.async { [weak self] in
            guard let self else { return }
            var info = ETTerminalInfo()
            info.row = rows
            info.column = cols
            info.width = widthPixels
            info.height = heightPixels
            self.sendPacket(header: .terminalInfo, payload: info.encode())
        }
    }

    private func sendPacket(header: ETPacketHeader, payload: [UInt8]) {
        guard !isStopped, writer != nil else { return }
        let packet = ETPacket(encrypted: false, header: header.rawValue, payload: payload)
        switch writer.write(packet) {
        case .ready(let bytes):
            sendFramed(bytes)
        case .bufferedOnly, .skipped:
            // Buffered for later delivery (or genuinely dropped once the
            // disconnect cap is hit) -- either way there's no live socket
            // to write to right now.
            break
        }
    }

    /// Sends already-framed bytes on the current `connection`, reporting a
    /// failure only if the completion fires while `connection` still *is*
    /// the instance this send was issued against. A reconnect (triggered by
    /// `handleConnectionFailure`/a rejected reconnect `ConnectResponse`)
    /// replaces `connection` with a fresh `NWConnection` while the old one's
    /// in-flight sends can still complete afterward -- without this check, a
    /// late failure completion from the superseded connection would call
    /// `handleConnectionFailure` again and cancel the brand-new reconnect
    /// attempt it raced against.
    private func sendFramed(_ bytes: [UInt8]) {
        let registeredConnection = connection
        connection.send(content: Data(bytes), completion: .contentProcessed { [weak self] error in
            guard let self, let error else { return }
            self.queue.async {
                guard registeredConnection === self.connection else { return }
                self.handleConnectionFailure(reason: "send error: \(error.localizedDescription)")
            }
        })
    }

    // MARK: - Connection lifecycle

    private func armConnection(isReconnect: Bool) {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.queue.async { self.handleConnectionReady(isReconnect: isReconnect) }
            case .failed(let error):
                self.queue.async { self.handleConnectionFailure(reason: "connection failed: \(error.localizedDescription)") }
            default:
                break
            }
        }
    }

    private func handleConnectionReady(isReconnect: Bool) {
        guard !isStopped else { return }
        oneShotBuffer = []
        oneShotStep = .connectResponse
        phase = .awaitingOneShot
        // A new NWConnection is a fresh TCP byte stream -- any bytes still
        // buffered inside the old packetStreamReader (a partially-received
        // packet from the connection that just died) must not leak into
        // parsing the new connection's bytes.
        packetStreamReader = ETPacketStreamReader()

        var request = ETConnectRequest()
        request.clientId = id
        request.version = Self.protocolVersion
        let framed = ETOneShotProto.frame(request.encode())
        sendFramed(framed)
        receiveLoop()
    }

    private func handleConnectionFailure(reason: String) {
        guard !isStopped, !hasReportedFatalError else { return }
        keepAliveTimer?.cancel()
        keepAliveTimer = nil

        guard reader != nil, writer != nil else {
            // Never got past the initial handshake -- nothing to recover,
            // this is a hard failure of the very first connection attempt.
            reportFatalError(TransportError.connectResponseRejected(status: nil, message: reason))
            return
        }

        writer.revive(connected: false)
        connection.stateUpdateHandler = nil
        connection.cancel()
        scheduleReconnect(reason: reason)
    }

    /// Bumps the failure count, gives up (via `reportFatalError`) once
    /// `maxConsecutiveReconnectFailures` is exceeded, and otherwise opens a
    /// fresh `NWConnection` after `reconnectBackoff`'s delay. Shared by
    /// `handleConnectionFailure` (a connection-level failure) and
    /// `handleConnectResponse`'s rejection branch (an application-level
    /// rejection of a reconnect attempt) -- both are just different ways a
    /// reconnect attempt can fail, and both deserve the same bounded retry.
    private func scheduleReconnect(reason: String) {
        consecutiveReconnectFailures += 1
        if consecutiveReconnectFailures > Self.maxConsecutiveReconnectFailures {
            reportFatalError(TransportError.reconnectGaveUp(reason: reason))
            return
        }
        let delay = Self.reconnectBackoff(forFailureCount: consecutiveReconnectFailures)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.isStopped, !self.hasReportedFatalError else { return }
            self.connection = NWConnection(host: self.host, port: self.port, using: .tcp)
            self.armConnection(isReconnect: true)
            self.connection.start(queue: self.queue)
        }
    }

    /// Not `private` so it's directly testable without needing a live
    /// `NWConnection` to trigger one of the real internal call sites --
    /// same reasoning as `MoshTransport.reportFatalError`.
    func reportFatalError(_ error: Error) {
        guard !hasReportedFatalError else { return }
        hasReportedFatalError = true
        onError?(error)
    }

    // MARK: - Receiving

    private func receiveLoop() {
        // Captured at registration time, not read from `self.connection`
        // inside the completion handler -- a reconnect (see
        // `handleConnectionFailure`/`scheduleReconnect`) can replace
        // `connection` with a fresh `NWConnection` while this receive is
        // still in flight on the old one. Without this guard, a late
        // completion delivering the old connection's leftover buffered
        // bytes would get fed into the *new* connection's freshly-reset
        // `packetStreamReader`/`reader` -- reconstructing garbage packets
        // from misaligned framing, or at best consuming a nonce step the
        // peer never used, either of which corrupts the crypto stream's
        // nonce sequence and surfaces as `ETSecretBox.OpenError` on this or
        // every subsequent decrypt. This is the same "unstructured
        // completion racing a torn-down instance" failure mode documented
        // for Mosh's reconnect storm and `disconnect()`/`attemptMoshUpgrade`
        // races in CLAUDE.md -- just on the receive path here instead of a
        // `Task`.
        let registeredConnection = connection
        registeredConnection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self else { return }
            self.queue.async {
                guard registeredConnection === self.connection else { return }
                if let data, !data.isEmpty {
                    self.handleIncoming(Array(data))
                }
                if let error {
                    self.handleConnectionFailure(reason: "receive error: \(error.localizedDescription)")
                    return
                }
                self.receiveLoop()
            }
        }
    }

    private func handleIncoming(_ bytes: [UInt8]) {
        guard !isStopped else { return }
        switch phase {
        case .awaitingOneShot:
            oneShotBuffer.append(contentsOf: bytes)
            handleOneShotBuffer()
        case .live:
            handleLiveBytes(bytes)
        }
    }

    private func handleOneShotBuffer() {
        do {
            guard let (payload, consumed) = try ETOneShotProto.parseOne(oneShotBuffer) else { return }
            let remainder = Array(oneShotBuffer[consumed...])
            oneShotBuffer = []

            switch oneShotStep {
            case .connectResponse:
                try handleConnectResponse(payload)
            case .sequenceHeader:
                try handleSequenceHeader(payload)
            case .catchupBuffer:
                try handleCatchupBuffer(payload)
            }

            // A step may have transitioned into `.live` (after
            // catchupBuffer) or into the next one-shot step -- either way,
            // any bytes past the message just parsed belong to whatever
            // phase is active now, not necessarily another one-shot message.
            if !remainder.isEmpty {
                handleIncoming(remainder)
            }
        } catch {
            reportFatalError(error)
        }
    }

    private func handleConnectResponse(_ payload: [UInt8]) throws {
        let response = try ETConnectResponse.decode(payload)
        guard response.status == .newClient || response.status == .returningClient else {
            guard reader != nil, writer != nil else {
                // Rejected on the very first connect -- nothing to recover,
                // this is a hard failure (bad id/passkey, incompatible
                // server) not worth retrying.
                throw TransportError.connectResponseRejected(status: response.status, message: response.error)
            }
            // Rejected on a *reconnect* -- see `consecutiveReconnectFailures`'
            // doc comment for why this is retried with backoff instead of
            // torn down immediately.
            keepAliveTimer?.cancel()
            keepAliveTimer = nil
            writer.revive(connected: false)
            connection.stateUpdateHandler = nil
            connection.cancel()
            scheduleReconnect(reason: "reconnect rejected (\(response.status.map { String(describing: $0) } ?? "nil")): \(response.error)")
            return
        }

        if reader == nil || writer == nil {
            // First connection: fresh crypto streams, one per direction,
            // matching ClientConnection::connect exactly -- the reader
            // decrypts the peer's (server's) stream, seeded with the
            // peer's own direction byte; the writer encrypts this side's
            // stream, seeded with its own.
            reader = ETBackedReader(cryptoStream: ETCryptoStream(key: key, directionByte: 1 /* SERVER_CLIENT_NONCE_MSB */))
            writer = ETBackedWriter(cryptoStream: ETCryptoStream(key: key, directionByte: 0 /* CLIENT_SERVER_NONCE_MSB */), connected: true)

            var payload = ETInitialPayload()
            payload.jumphost = false
            sendPacket(header: .initialPayload, payload: payload.encode())
            // Still one-shot-framed protocol messages, but now these ride
            // as ordinary encrypted Packets -- `sendPacket` already routes
            // through `writer`/`ETPacketStreamReader` framing, so nothing
            // else changes here; the *next* thing this transport expects
            // is an ordinary live packet (`.initialResponse`), not another
            // one-shot message.
            phase = .live
        } else {
            // Reconnect: reuse the existing reader/writer (crypto state and
            // sequence numbers persist across a reconnect -- only the
            // socket association changes), then exchange SequenceHeader/
            // CatchupBuffer before resuming live traffic. Deliberately
            // does *not* call `writer.revive(connected: true)` here --
            // `Connection::recover` (`src/base/Connection.cpp`) calls
            // `writer->recover(...)` *before* `writer->revive(socketFd)`,
            // relying on `recover()`'s own guard that it must run while
            // still disconnected. An earlier version of this method called
            // `writer.revive(connected: true)` at this point, which made
            // `handleSequenceHeader`'s later `writer.recover(...)` throw
            // `.stillConnected` -- caught only by a real reconnect test
            // against a live `etserver` (a network blackout via iptables,
            // not a hand-crafted unit test), exactly the ordering mistake
            // CLAUDE.md's own roadmap warned this step was at risk of.
            var header = ETSequenceHeader()
            header.sequenceNumber = Int32(truncatingIfNeeded: reader.sequenceNumber)
            let framed = ETOneShotProto.frame(header.encode())
            sendFramed(framed)
            oneShotStep = .sequenceHeader
            phase = .awaitingOneShot
        }
    }

    private func handleSequenceHeader(_ payload: [UInt8]) throws {
        let remoteHeader = try ETSequenceHeader.decode(payload)
        let recoveredMessages = try writer.recover(lastValidSequenceNumber: Int64(remoteHeader.sequenceNumber))
        var catchup = ETCatchupBuffer()
        catchup.buffer = recoveredMessages
        let framed = ETOneShotProto.frame(catchup.encode())
        sendFramed(framed)
        oneShotStep = .catchupBuffer
    }

    private func handleCatchupBuffer(_ payload: [UInt8]) throws {
        let catchup = try ETCatchupBuffer.decode(payload)
        // Matches `Connection::recover`'s exact order: `reader->revive(...)`
        // then `writer->revive(...)`, both only after `writer->recover(...)`
        // (in `handleSequenceHeader`) already ran while still disconnected.
        reader.revive(replayPackets: catchup.buffer)
        writer.revive(connected: true)
        phase = .live
        drainReplayQueue()
        startKeepAliveTimer()
        signalEstablished()
    }

    private func handleLiveBytes(_ bytes: [UInt8]) {
        do {
            for packet in try packetStreamReader.feed(bytes) {
                try handleLivePacket(packet)
            }
        } catch {
            reportFatalError(error)
        }
    }

    private func drainReplayQueue() {
        do {
            while let packet = try reader.nextReplayPacket() {
                try handleLivePacket(packet, isReplay: true)
            }
        } catch {
            reportFatalError(error)
        }
    }

    private func handleLivePacket(_ rawPacket: ETPacket, isReplay: Bool = false) throws {
        let packet = isReplay ? rawPacket : try reader.consumeLivePacket(rawPacket)
        guard let header = ETPacketHeader(rawValue: packet.header) else {
            throw TransportError.unknownPacketHeader(packet.header)
        }
        switch header {
        case .initialResponse:
            let response = try ETInitialResponse.decode(packet.payload)
            if !response.error.isEmpty {
                throw TransportError.initialResponseError(response.error)
            }
            startKeepAliveTimer()
            signalEstablished()
        case .terminalBuffer:
            let tb = try ETTerminalBuffer.decode(packet.payload)
            onOutput?(tb.buffer)
        case .keepAlive:
            waitingOnKeepAlive = false
        default:
            // PORT_FORWARD_*/JUMPHOST_INIT -- out of scope, see CLAUDE.md.
            throw TransportError.unknownPacketHeader(packet.header)
        }
    }

    private func signalEstablished() {
        // A real success (first connect or a completed reconnect) means
        // whatever's currently happening network-wise genuinely works --
        // reset the failure count so it only ever measures *consecutive*
        // reconnect failures, not ones accumulated earlier in a long
        // session with multiple, unrelated roams.
        consecutiveReconnectFailures = 0
        hasSignaledEstablishedOnce = true
        onEstablished?()
    }

    // MARK: - Keepalive

    private func startKeepAliveTimer() {
        keepAliveTimer?.cancel()
        waitingOnKeepAlive = false
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.keepAliveInterval, repeating: Self.keepAliveInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if self.waitingOnKeepAlive {
                self.handleConnectionFailure(reason: "missed a keepalive")
                return
            }
            self.sendPacket(header: .keepAlive, payload: [])
            self.waitingOnKeepAlive = true
        }
        timer.resume()
        keepAliveTimer = timer
    }
}
