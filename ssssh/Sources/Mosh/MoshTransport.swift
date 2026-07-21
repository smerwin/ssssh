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
/// - **A single acked position plus a small equivalence range, not a
///   retained multi-state window.** Real mosh keeps a whole history of
///   received host states (a map from state number to a full `Complete`
///   object) so a diff anchored on any of them can be applied onto its own
///   correct starting point. This transport doesn't model the terminal
///   itself (see `MoshPredictionEngine`'s doc comment on why), so it has no
///   per-state framebuffer to apply an old diff onto -- it can only ever
///   safely apply a diff *in full*, onto whatever's already on screen, and
///   only when that's provably the same framebuffer the diff was computed
///   against. See `equivalentSince`'s doc comment for exactly what "provably
///   the same" means and why anything outside that range is dropped
///   outright rather than partially applied.
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

    /// Fixed heartbeat tick interval -- not mosh's adaptive
    /// ACK_INTERVAL/SRTT-driven timing, just often enough to keep
    /// NAT/firewall UDP mappings alive and to relay a fresh ack_num
    /// promptly when idle.
    private static let heartbeatInterval: TimeInterval = 3

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
    /// The oldest state number whose framebuffer is *provably* identical to
    /// the one `myAckedStateNum` currently reflects, i.e. every step from
    /// here up to `myAckedStateNum` applied an empty diff (nothing actually
    /// changed on screen). Together with `myAckedStateNum` this defines the
    /// range of `old_num` values a diff can safely be anchored on --
    /// `[equivalentSince, myAckedStateNum]` -- and it's the *only* thing
    /// that determines whether an incoming diff is safe to apply.
    ///
    /// This exists because a real mosh-server pipelines: it can send
    /// several successive diffs all anchored on the same `old_num` before
    /// it's confirmed (via my `ack_num`) that I've caught up to any of
    /// them, since its own `assumed_receiver_state` only optimistically
    /// advances once enough time has passed to assume an earlier send
    /// arrived. Verified against a real mosh-server: a login-banner burst
    /// produced two successive states anchored on the same initial
    /// reference -- an empty, content-free ack-only tick, then a second
    /// one carrying the actual banner text. Validating `old_num` against
    /// only the single latest `myAckedStateNum` would silently drop that
    /// second, real-content sibling (its base no longer matches "current"),
    /// so a still-equivalent older baseline has to stay acceptable too.
    ///
    /// Why this can only ever be a range check, never a byte-level merge:
    /// `HostBytes.hoststring` is **not** a slice of one giant append-only
    /// output log. Confirmed by reading mosh's own `Complete::diff_from`
    /// (`src/statesync/completeterminal.cc`): it's computed as
    /// `display.new_frame(existing_fb, current_fb)`, a genuine
    /// framebuffer-to-framebuffer diff -- the same differential-redraw
    /// algorithm mosh uses to draw a terminal efficiently, not literal
    /// captured PTY bytes. Two diffs computed from the same or different
    /// reference states are *not* guaranteed to be byte-prefixes of one
    /// another; they can use different cursor jumps, overwrite different
    /// cells, or omit lines that didn't change relative to *their own*
    /// reference even though other diffs re-anchor differently. An earlier
    /// version of this code tried to reconcile overlapping resends by
    /// comparing cumulative byte lengths across messages and feeding an
    /// assumed "new tail" -- against plain linear shell output this
    /// happened to work (a framebuffer diff for pure scrolling text
    /// degenerates to look append-only), which is exactly why it passed
    /// this project's Docker verification. Against a program that redraws
    /// its own UI with absolute cursor positioning (confirmed with a real
    /// report: Claude Code's own CLI over Mosh, corrupted/garbled output
    /// and wrong layout starting immediately at launch, when its UI first
    /// paints), successive sibling diffs are routinely *not* prefix-related,
    /// so that length arithmetic fed wrong tails and sometimes sliced
    /// straight into the middle of an ANSI escape sequence -- corrupting
    /// output outright, not just duplicating it.
    ///
    /// The only diff this transport can ever safely apply is one anchored
    /// on a state whose framebuffer is known, by this empty-diff chain, to
    /// be identical to the one currently on screen -- and when it is safe,
    /// it must be applied *in full*, never sliced. A resend anchored
    /// *outside* `[equivalentSince, myAckedStateNum]` is dropped whole
    /// rather than guessed at: whatever content it uniquely carries isn't
    /// lost for good, since the server's own next regular tick will
    /// recompute a fresh, correctly-anchored diff once it learns (via ack)
    /// where this client actually is -- the same self-healing property
    /// that makes mosh's own retransmission model work at all.
    private var equivalentSince: UInt64 = 0
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

    /// Called externally by `SSHConnection`, never from a closure already
    /// running on `queue` -- safe to route synchronously through it like
    /// every other mutator here (`rebuildConnection`, `armConnection`'s
    /// handler, `send`, `resize`). Without this, `stop()` used to mutate
    /// `isStopped`/`heartbeatTimer`/`pathMonitor`/`connection` directly from
    /// the caller's own thread, unsynchronized against a `rebuildConnection`
    /// that might be concurrently reassigning `connection` on `queue` --
    /// e.g. disconnecting mid-roam could race `stop()`'s `connection.cancel()`
    /// against `rebuildConnection`'s `connection = NWConnection(...)` on the
    /// same reference-typed `var`.
    func stop() {
        queue.sync {
            isStopped = true
            heartbeatTimer?.cancel()
            heartbeatTimer = nil
            pathMonitor?.cancel()
            pathMonitor = nil
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
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
        timer.schedule(deadline: .now() + Self.heartbeatInterval, repeating: Self.heartbeatInterval)
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

    /// Not `private` so it's directly testable with hand-crafted, encrypted
    /// datagrams instead of needing a real `NWConnection` and a real
    /// (nondeterministic) server to reproduce a specific packet ordering.
    func handleIncoming(_ datagram: [UInt8]) {
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
        // Clamped to `sentEvents.count`: `ackNum` is a value the server
        // sends us, and it can never legitimately exceed how many events
        // we've actually sent it, but nothing stops a compromised or
        // malformed server from claiming otherwise. Unclamped, a bogus
        // `ackNum` becomes `sendState()`'s `oldNum` and crashes on
        // `sentEvents[Int(oldNum)...]` -- one hostile packet, deterministic
        // trap, no auth bypass needed since the sender already holds a
        // valid session key.
        serverAckedCount = min(max(serverAckedCount, instruction.ackNum), UInt64(sentEvents.count))

        // Dedup/safety check: a state at or behind where we already are is
        // a resend we've fully applied already. Otherwise, only ever apply
        // a diff anchored on a state whose framebuffer is provably
        // identical to what's already on screen -- see `equivalentSince`'s
        // doc comment for why that's the *only* thing that makes applying
        // a diff safe, and why anything outside that range is dropped
        // whole rather than partially applied.
        guard instruction.newNum > myAckedStateNum else { return }
        guard instruction.oldNum >= equivalentSince, instruction.oldNum <= myAckedStateNum else {
            return // anchored on a framebuffer state we can no longer prove matches the screen
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

        // An empty diff means this state's framebuffer is identical to its
        // reference's, so the equivalence range simply extends to include
        // it. Real content means the framebuffer just changed -- only the
        // state we're about to reach is known-equivalent to itself, so the
        // range collapses to start there.
        if !fullContent.isEmpty {
            equivalentSince = instruction.newNum
        }
        myAckedStateNum = instruction.newNum
        if !fullContent.isEmpty {
            onOutput?(fullContent)
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
