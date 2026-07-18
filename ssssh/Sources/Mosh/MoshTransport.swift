import Foundation
import Network

/// A live Mosh session's UDP transport: wraps `MoshSession` (crypto/framing),
/// `MoshFragmenter`/`MoshFragmentAssembly` (compression + fragmentation),
/// and `MoshUserMessage`/`MoshHostMessage` (the state-sync application
/// protocol) over an `NWConnection` to the `mosh-server` port
/// `MoshBootstrap` reports.
///
/// This is a deliberately simplified client compared to mosh's own
/// `Network::Transport`/`TransportSender`:
/// - **No pipelining.** Real mosh can have several unacknowledged outgoing
///   states in flight (optimistically assuming recent-enough sends were
///   received) and resends the exact same numbered diff on timeout. This
///   always anchors the next outgoing diff on the last state the server
///   has *actually* acknowledged, and simply recomputes a fresh diff (with
///   a fresh state number) from there on every send -- correct per the
///   protocol (the receiver dedupes by state number and validates
///   `old_num` against what it has), just less bandwidth-efficient under
///   loss or high latency.
/// - **Single-position receiver, not a retained window.** Real mosh keeps
///   several recently-received host states so an out-of-order arrival can
///   still be used. This only ever tracks its current position and drops
///   anything whose `old_num` doesn't match it exactly, relying on the
///   server's own periodic resends to eventually redeliver in order.
/// - **No adaptive RTT/congestion control.** Sends happen immediately on
///   new input plus a fixed heartbeat interval, not mosh's SRTT-driven
///   timeout/backoff.
///
/// None of that affects wire compatibility -- a real `mosh-server` cannot
/// tell the difference between this and the reference client from any
/// single packet, only from these coarser efficiency/robustness behaviors.
///
/// **Roaming**: confirmed by reading mosh's own `network.cc` that address
/// roaming is entirely server-side -- a real `mosh-server` just accepts a
/// new client address the moment a packet from it decrypts correctly
/// ("only client can roam" guards this on the server so a server can't
/// wander, but nothing gates the client). So the client's whole job is to
/// survive its own local network changing without restarting the session:
/// `NWPathMonitor` watches for a materially different local path (a
/// changed set of available interfaces, e.g. Wi-Fi to cellular), and
/// `rebuildConnection()` tears down and recreates the underlying
/// `NWConnection` to the same host/port on that signal -- or on the
/// existing connection failing outright -- while leaving `session`,
/// sequence counters, and all application state (`sentEvents`,
/// `myAckedStateNum`, etc.) completely untouched. Never resetting the
/// per-direction sequence counters across a rebuild is load-bearing, not
/// just an optimization: reusing a sequence number under the same key is
/// exactly the nonce reuse `MoshOCB`'s doc comment says is catastrophic.
final class MoshTransport: @unchecked Sendable {
    /// Raw bytes reconstructed from the server's `HostBytes` instructions,
    /// ready to feed directly into a terminal view (same shape as
    /// `SSHConnection.onOutput`).
    var onOutput: (([UInt8]) -> Void)?
    var onError: ((Error) -> Void)?
    /// Fires exactly once, the first time any authenticated, correctly
    /// versioned packet arrives from the server -- proof the UDP round
    /// trip actually works (mosh-server never sends first, so silence
    /// here within a timeout typically means a firewall is blocking UDP,
    /// not that the server is merely slow). Callers use this to decide
    /// whether to commit to Mosh or fall back to SSH; it fires regardless
    /// of whether the packet's diff ends up applicable.
    var onEstablished: (() -> Void)?
    private var hasSignaledEstablished = false

    private var connection: NWConnection
    private let session: MoshSession
    private let queue = DispatchQueue(label: "com.smerwin.ssssh.mosh-transport")
    private let fragmenter = MoshFragmenter()
    private let assembly = MoshFragmentAssembly()

    // MARK: Roaming -- see the type doc comment.
    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private var pathMonitor: NWPathMonitor?
    private var lastPathIdentity: String?
    private var isStopped = false
    private var consecutiveRebuildFailures = 0
    /// After this many back-to-back rebuild failures, stop retrying
    /// automatically and report a hard failure via `onError` instead --
    /// otherwise a genuinely dead network would retry forever, silently.
    private static let maxConsecutiveRebuildFailures = 5
    /// Enforces real wall-clock spacing between consecutive rebuild
    /// attempts -- without this, a genuinely still-unavailable network
    /// (not just one stale socket, e.g. iOS broadly suspending networking
    /// while this app is backgrounded) lets each freshly-rebuilt
    /// connection fail again just as fast as the last: `NWConnection`'s
    /// send/receive completions all run on this same serial `queue`, so a
    /// fast, repeated failure can cascade through the entire
    /// `maxConsecutiveRebuildFailures` budget within milliseconds --
    /// reported directly as a Mosh session still dying with "NWError 89"
    /// (POSIX ECANCELED) when the phone sleeps, even after the send-path
    /// fix that made a single such failure retry instead of dying
    /// immediately. Starts in the past so the very first attempt after any
    /// failure stays immediate -- the common roaming case (a real
    /// network/interface change) usually recovers on that first retry, and
    /// delaying it would make an ordinary Wi-Fi handoff feel sluggish.
    private var nextAllowedRebuildAttempt = Date.distantPast
    /// Mirrors `SSHConnection`'s own reconnect backoff shape (1, 2, 4, 8,
    /// 16... capped at 30s) so repeated failures are spaced out over real
    /// time long enough for the phone to actually wake back up, instead of
    /// being exhausted in a single instant. Not `private` so it's directly
    /// testable, same reasoning as `reportFatalError`.
    static func rebuildBackoff(forFailureCount count: Int) -> TimeInterval {
        min(pow(2.0, Double(max(count - 1, 0))), 30)
    }
    /// Set the first (and only) time `onError` fires, from any of this
    /// type's several independent call sites (`rebuildConnection`'s own
    /// give-up, a send failure, a protocol-version mismatch). Without this,
    /// a persistently broken network kept calling `onError` again on
    /// *every* subsequent rebuild attempt -- `consecutiveRebuildFailures`
    /// only ever grows, it's never capped/reset once exceeded, so nothing
    /// stopped `rebuildConnection` from re-triggering the give-up report
    /// every ~3-12s forever. Each firing reached `SSHConnection`'s
    /// per-session `onError` closure, which unconditionally spawned a
    /// fresh `finishWithDrop`/`onDrop`/reconnect cycle -- confirmed in
    /// production as dozens of concurrent reconnect-and-upgrade-to-Mosh
    /// attempts stacking up for a single dropped session. `onError` must
    /// fire at most once per transport instance; from then on this
    /// transport is done and waiting to be torn down by its owner.
    private var hasReportedFatalError = false

    /// Not `private` so it's directly testable without needing a live
    /// `NWConnection` to trigger one of the real internal call sites.
    func reportFatalError(_ error: Error) {
        guard !hasReportedFatalError else { return }
        hasReportedFatalError = true
        onError?(error)
    }
    /// A plain UDP blackhole (packets silently dropped, e.g. a NAT mapping
    /// expiring or a network going out of range) doesn't necessarily
    /// surface as an `NWConnection` failure at all -- UDP has no
    /// delivery/ack signal at the socket layer, so `send` can keep
    /// "succeeding" into the void. `lastReceivedAt` tracks the last time
    /// any authenticated packet arrived, and the heartbeat tick below
    /// proactively rebuilds if that's gone quiet too long -- mirroring why
    /// mosh's own client tracks "server late"/"reply late" separately from
    /// outright connection errors (`NotificationEngine` in
    /// `terminaloverlay.h`, similar thresholds).
    private var lastReceivedAt = Date()
    private static let silenceRebuildThreshold: TimeInterval = 12

    /// mosh's own conservative default application-datagram MTU
    /// (`Connection::DEFAULT_SEND_MTU` in `network.h`) minus the wire
    /// overhead this transport itself adds (8-byte nonce + 4-byte
    /// timestamp/timestamp-reply header + 16-byte OCB tag = 28 bytes).
    private static let effectiveMTU = 500 - 28

    // MARK: Outgoing (ClientBuffers.UserMessage / "UserStream") state.
    // State numbers are defined here as the count of `sentEvents` at the
    // time a state was sent -- see the type's doc comment for why that's a
    // valid, simpler stand-in for mosh's own opaque state numbering.
    private enum PendingEvent {
        case keystrokeByte(UInt8)
        case resize(width: Int, height: Int)
    }
    private var sentEvents: [PendingEvent] = []
    private var serverAckedCount: UInt64 = 0
    private var outgoingSequence: UInt64 = 0

    // MARK: Incoming (HostBuffers.HostMessage / "HostStream") state.
    private var myAckedStateNum: UInt64 = 0
    /// A real mosh-server pipelines: it can send several successive
    /// diffs all anchored on the same `old_num` before it's confirmed
    /// (via my `ack_num`) that I've caught up to any of them, because its
    /// own `assumed_receiver_state` only optimistically advances once
    /// enough time has passed to assume an earlier send arrived. Verified
    /// against a real mosh-server: a login-banner burst produced two
    /// successive states both anchored on the same initial reference.
    /// Validating `old_num` against only the single latest
    /// `myAckedStateNum` silently dropped the second one's real content
    /// (its base no longer matched "current"), so recently-superseded
    /// baselines stay valid a while longer here too -- capped in size
    /// since this only needs to cover a short pipelining burst, not
    /// mosh's own unbounded-until-throwaway_num retention.
    private var recentBaselines: [UInt64] = []
    private static let maxRetainedBaselines = 16
    /// What's already been fed to `onOutput` for each retained baseline,
    /// keyed by that instruction's `old_num`. A real mosh-server's tick
    /// loop can resend "the current diff" under a fresh `new_num` even
    /// when nothing new has happened, producing a sibling whose content is
    /// byte-for-byte identical to (or a simple extension of) one already
    /// applied from the same baseline -- verified against a real
    /// mosh-server, where a second, redundant tick reproduced the exact
    /// same 126 bytes of shell output already fed from an earlier sibling,
    /// and re-feeding it duplicated the rendered command/output. Applying
    /// an instruction now only ever feeds the suffix beyond what's already
    /// recorded here for its `old_num`, so an identical resend feeds
    /// nothing further and a genuinely longer sibling only feeds its new
    /// tail. Pruned in lockstep with `recentBaselines`.
    private var contentFedForBaseline: [UInt64: [UInt8]] = [:]
    private var highestReceivedSequence: UInt64?

    private var heartbeatTimer: DispatchSourceTimer?

    init(host: String, port: UInt16, sessionKey: [UInt8]) {
        self.session = MoshSession(key: sessionKey)
        self.host = .init(host)
        self.port = .init(rawValue: port)!
        self.connection = NWConnection(host: self.host, port: self.port, using: .udp)
    }

    func start() {
        armConnection()
        connection.start(queue: queue)
        receiveLoop()
        startHeartbeat()
        startPathMonitor()
        // The first packet is what lets the server learn our address (it
        // never sends unsolicited) -- send immediately rather than waiting
        // for the first heartbeat tick.
        sendState()
    }

    /// Wires `stateUpdateHandler` on whichever `NWConnection` is current --
    /// called both from `start()` and after `rebuildConnection()` replaces
    /// `connection` with a fresh instance.
    private func armConnection() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .failed = state {
                self.queue.async { self.rebuildConnection(reason: "connection failed") }
            }
        }
    }

    // MARK: - Roaming

    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let identity = Self.pathIdentity(path)
            self.queue.async {
                defer { self.lastPathIdentity = identity }
                // The monitor's first callback just reports the path we
                // already started on -- only a path that's both usable and
                // different from the last one we knew about means the
                // local network actually changed under us.
                guard path.status == .satisfied, let last = self.lastPathIdentity, last != identity else { return }
                self.rebuildConnection(reason: "network path changed")
            }
        }
        monitor.start(queue: queue)
        pathMonitor = monitor
    }

    private static func pathIdentity(_ path: NWPath) -> String {
        path.availableInterfaces.map { "\($0.type):\($0.name)" }.joined(separator: ",")
    }

    /// Tears down the current `NWConnection` and opens a fresh one to the
    /// same host/port, preserving every other piece of state untouched
    /// (see the type doc comment on why that's essential, not incidental).
    /// Immediately re-sends the current outgoing state once the new
    /// connection is up, so a real `mosh-server` learns the new address as
    /// quickly as possible rather than waiting for the next heartbeat.
    private func rebuildConnection(reason: String) {
        // Once a fatal error has been reported, this transport is done --
        // don't keep rebuilding (and don't let a still-firing heartbeat or
        // path-monitor callback re-trigger `reportFatalError` and report
        // the same give-up again; that's exactly what used to keep firing
        // every ~3-12s indefinitely).
        guard !isStopped, !hasReportedFatalError else { return }
        // Also don't re-enter before the backoff from the *previous*
        // attempt has elapsed -- see `nextAllowedRebuildAttempt`'s doc
        // comment. A call arriving too soon is a symptom of the same
        // still-broken network the last attempt already accounted for,
        // not a new, independent failure worth spending another attempt on.
        guard Date() >= nextAllowedRebuildAttempt else { return }

        connection.stateUpdateHandler = nil
        connection.cancel()

        connection = NWConnection(host: host, port: port, using: .udp)
        armConnection()
        connection.start(queue: queue)
        receiveLoop()

        consecutiveRebuildFailures += 1
        if consecutiveRebuildFailures > Self.maxConsecutiveRebuildFailures {
            reportFatalError(MoshTransportError.roamingGaveUp(reason: reason))
            return
        }
        nextAllowedRebuildAttempt = Date().addingTimeInterval(Self.rebuildBackoff(forFailureCount: consecutiveRebuildFailures))
        sendState()
    }

    func stop() {
        isStopped = true
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    func send(_ bytes: [UInt8]) {
        queue.async { [weak self] in
            guard let self else { return }
            for byte in bytes {
                self.sentEvents.append(.keystrokeByte(byte))
            }
            self.sendState()
        }
    }

    func resize(cols: Int, rows: Int) {
        queue.async { [weak self] in
            guard let self else { return }
            self.sentEvents.append(.resize(width: cols, height: rows))
            self.sendState()
        }
    }

    // MARK: - Sending

    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // Not mosh's adaptive ACK_INTERVAL/SRTT-driven timing -- a fixed
        // interval, just often enough to keep NAT/firewall UDP mappings
        // alive and to relay a fresh ack_num promptly when idle.
        timer.schedule(deadline: .now() + 3, repeating: 3)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if Date().timeIntervalSince(self.lastReceivedAt) > Self.silenceRebuildThreshold {
                self.rebuildConnection(reason: "no response from server in \(Int(Self.silenceRebuildThreshold))s")
                return
            }
            self.sendState()
        }
        timer.resume()
        heartbeatTimer = timer
    }

    /// Builds and sends one `MoshTransportInstruction` reflecting whatever
    /// hasn't yet been acknowledged by the server. Safe to call repeatedly
    /// with no new events -- it degenerates into a content-free ack/keepalive
    /// (`old_num == new_num`), which is itself a valid, real Mosh packet.
    private func sendState() {
        let oldNum = serverAckedCount
        let newNum = UInt64(sentEvents.count)

        var instruction = MoshTransportInstruction()
        instruction.oldNum = oldNum
        instruction.newNum = newNum
        instruction.ackNum = myAckedStateNum
        instruction.throwawayNum = oldNum
        instruction.diff = Self.serializeUserMessage(for: Array(sentEvents[Int(oldNum)...]))

        do {
            let fragments = try fragmenter.makeFragments(for: instruction, mtu: Self.effectiveMTU)
            for fragment in fragments {
                sendDatagram(fragment.serialize())
            }
        } catch {
            reportFatalError(error)
        }
    }

    private func sendDatagram(_ payload: [UInt8]) {
        let sequence = outgoingSequence
        outgoingSequence += 1
        let datagram = session.encrypt(
            direction: .toServer,
            sequence: sequence,
            timestamp: UInt16(truncatingIfNeeded: Int(Date().timeIntervalSince1970 * 1000)),
            timestampReply: 0,
            payload: payload
        )
        connection.send(content: Data(datagram), completion: .contentProcessed { [weak self] error in
            guard let self, let error else { return }
            // Same reasoning as `receiveLoop`'s error handling: a send
            // failure on the live connection is exactly what roaming exists
            // to recover from, not an immediate fatal error. Concretely,
            // this is the path that used to surface as "NWError 89"
            // (POSIX ECANCELED) right after resuming a backgrounded
            // session -- iOS can invalidate a UDP `NWConnection` while the
            // app is suspended without ever posting a `.failed` state
            // update, so the first heartbeat send after resuming was the
            // first thing to discover it, and reporting that as fatal
            // killed the whole session instead of transparently rebuilding
            // it the way a Wi-Fi-to-cellular handoff already does.
            self.rebuildConnection(reason: "send error: \(error.localizedDescription)")
        })
    }

    private static func serializeUserMessage(for events: [PendingEvent]) -> [UInt8] {
        var instructions: [MoshUserInstruction] = []
        for event in events {
            switch event {
            case .keystrokeByte(let byte):
                // Combine consecutive keystroke bytes into one Keystroke
                // instruction, matching `UserStream::diff_from`'s own
                // merge-with-previous behavior.
                if case .keystroke(var bytes) = instructions.last {
                    bytes.append(byte)
                    instructions[instructions.count - 1] = .keystroke(bytes)
                } else {
                    instructions.append(.keystroke([byte]))
                }
            case .resize(let width, let height):
                instructions.append(.resize(width: width, height: height))
            }
        }
        return MoshUserMessage(instructions: instructions).serialize()
    }

    // MARK: - Receiving

    private func receiveLoop() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.handleIncoming(Array(data))
            }
            if let error {
                // A receive error on the live connection is exactly the
                // kind of thing roaming exists to recover from -- try
                // rebuilding rather than treating it as immediately fatal.
                self.rebuildConnection(reason: "receive error: \(error.localizedDescription)")
                return
            }
            self.receiveLoop()
        }
    }

    private func handleIncoming(_ datagram: [UInt8]) {
        let message: MoshSession.Message
        do {
            message = try session.decrypt(datagram)
        } catch {
            return // Failed authentication -- silently drop, matching mosh's own behavior for a corrupt/forged packet.
        }
        // A real, authenticated packet made it all the way through, so
        // whatever connection we're currently on genuinely works -- reset
        // the rebuild-failure count (and its backoff) so it only ever
        // measures *consecutive* failed rebuilds, not roaming events
        // accumulated over the whole session's lifetime, and reset the
        // silence clock the heartbeat tick checks.
        consecutiveRebuildFailures = 0
        nextAllowedRebuildAttempt = .distantPast
        lastReceivedAt = Date()

        // Reject anything not actually from the server, and any sequence
        // we've already seen or gone past (minimal replay protection --
        // real mosh's `Connection::recv` enforces a similar monotonic
        // check per direction).
        guard message.direction == .toClient else { return }
        if let highest = highestReceivedSequence, message.sequence <= highest { return }
        highestReceivedSequence = message.sequence

        guard let fragment = try? MoshFragment.parse(message.payload) else { return }
        guard assembly.addFragment(fragment) else { return }
        guard let instruction = try? assembly.takeAssembly() else { return }
        guard instruction.protocolVersion == MoshTransportInstruction.expectedProtocolVersion else {
            reportFatalError(MoshTransportError.protocolVersionMismatch)
            return
        }

        if !hasSignaledEstablished {
            hasSignaledEstablished = true
            onEstablished?()
        }

        // Ack processing happens regardless of whether the diff below ends
        // up applicable, matching `Transport::recv`'s ordering in mosh.
        serverAckedCount = max(serverAckedCount, instruction.ackNum)

        // Dedup first: a state at or behind where we already are is either
        // a resend we've fully applied, or superseded by something later
        // we've already applied instead -- see `recentBaselines`'s doc
        // comment for why a later state can validly supersede an earlier
        // sibling built from the same reference.
        guard instruction.newNum > myAckedStateNum else { return }
        guard instruction.oldNum == myAckedStateNum || recentBaselines.contains(instruction.oldNum) else {
            return // anchored on a reference we've never seen; wait for a resend anchored correctly
        }
        guard let hostMessage = try? MoshHostMessage.parse(instruction.diff) else { return }

        var fullContent: [UInt8] = []
        for hostInstruction in hostMessage.instructions {
            switch hostInstruction {
            case .hostBytes(let bytes):
                fullContent.append(contentsOf: bytes)
            case .resize, .echoAck:
                break // Nothing to do yet -- see the type doc comment on remaining gaps.
            }
        }

        // Only feed the part of this baseline's content we haven't already
        // fed -- see `contentFedForBaseline`'s doc comment for why a
        // sibling from the same `old_num` can carry content that's
        // identical to (or a simple extension of) one already applied.
        let alreadyFed = contentFedForBaseline[instruction.oldNum] ?? []
        let outputBytes: [UInt8]
        if fullContent.count >= alreadyFed.count, Array(fullContent.prefix(alreadyFed.count)) == alreadyFed {
            outputBytes = Array(fullContent.dropFirst(alreadyFed.count))
        } else {
            // Diverges from what was already fed for this baseline --
            // shouldn't normally happen, but feed everything rather than
            // silently lose data.
            outputBytes = fullContent
        }
        contentFedForBaseline[instruction.oldNum] = fullContent

        recentBaselines.append(myAckedStateNum)
        if recentBaselines.count > Self.maxRetainedBaselines {
            let dropped = recentBaselines.prefix(recentBaselines.count - Self.maxRetainedBaselines)
            recentBaselines.removeFirst(recentBaselines.count - Self.maxRetainedBaselines)
            for baseline in dropped {
                contentFedForBaseline[baseline] = nil
            }
        }

        myAckedStateNum = instruction.newNum
        if !outputBytes.isEmpty {
            onOutput?(outputBytes)
        }
    }
}

enum MoshTransportError: LocalizedError {
    case protocolVersionMismatch
    case roamingGaveUp(reason: String)

    var errorDescription: String? {
        switch self {
        case .protocolVersionMismatch:
            return "Mosh protocol version mismatch."
        case .roamingGaveUp(let reason):
            return "Mosh connection could not recover (\(reason))."
        }
    }
}
