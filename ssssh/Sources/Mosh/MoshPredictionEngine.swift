import Foundation

/// Predictive local echo: render typed characters immediately, before the
/// server's own echo arrives, so typing over Mosh feels instant even on a
/// slow link -- mosh's signature responsiveness feature.
///
/// This is a deliberately simplified stand-in for mosh's real
/// `Overlay::PredictionEngine` (`src/frontend/terminaloverlay.cc`), which
/// maintains its own full mirrored terminal framebuffer and overlays
/// predicted cells onto it with epoch tracking, glitch detection, and
/// SRTT-adaptive show/hide. This app has no parallel terminal model --
/// `SSHConnection`/`MoshTransport` feed raw bytes straight into SwiftTerm
/// (see CLAUDE.md's Mosh section on why that's normally sufficient) -- and
/// building one just for prediction would be exactly the kind of
/// complexity that section already chose to avoid. Instead of *modeling*
/// the terminal to know where a prediction is and reconcile it later, this
/// predicts by drawing an underlined preview character and then moving the
/// cursor back to exactly where it started -- so the terminal's own real
/// cursor position never advances until a real, confirmed byte arrives and
/// naturally overwrites the same cell.
///
/// **This assumption breaks down against raw-mode, self-redrawing programs**
/// -- confirmed against a real report of exactly this: running `claude`
/// (Claude Code's own CLI) over a Mosh session showed glitchy output and
/// underlined blank cells (rendering as stray underscores) left behind
/// under the input line. Programs like that don't echo typed characters
/// sequentially in place; they redraw their own input box using absolute
/// cursor positioning, so a prediction that's abandoned (see `predict`/
/// `reconcile` below) before a real byte ever lands on its exact cell was
/// previously left on screen forever, and a program that constantly
/// redraws like this abandons *most* predictions, making that the common
/// case rather than the rare one the original design assumed. Two things
/// now guard against this:
/// 1. Abandoning a prediction (for any reason) now returns an explicit
///    "erase what I already drew" instruction (`CSI <n> X`, Erase
///    Character -- blanks cells at the cursor without moving it) instead
///    of just forgetting about it, so a stale underline can't linger.
/// 2. `misprediction` tracks *genuine* mismatches -- a real byte that
///    contradicts an actively pending prediction, as opposed to simply
///    choosing not to predict an unpredictable keystroke (Enter, Backspace,
///    arrows are normal and expected, not a sign anything's wrong). Once
///    that happens `mispredictionCircuitBreakerThreshold` times, this
///    engine stops predicting for the rest of its lifetime (one
///    `MoshPredictionEngine` lives as long as its `TerminalSessionController`,
///    i.e. the whole session including any Mosh roaming reconnects) rather
///    than continuing to flicker predictions on and off against a program
///    it's already shown it can't keep up with.
///
/// Remaining deliberate simplifications versus real mosh, all in the
/// direction of "never wrong, sometimes less helpful":
/// - Only predicts a single, plain printable ASCII byte (0x20-0x7E) sent
///   on its own -- not Enter, Backspace, arrow keys, or anything
///   multi-byte (real mosh predicts some of these too, under stricter
///   rules).
/// - No SRTT-adaptive show/hide -- predictions always render (underlined)
///   as soon as the caller decides it's safe to ask (see
///   `TerminalSessionController`'s alternate-screen-buffer check) and the
///   circuit breaker above hasn't tripped.
/// - No glitch/epoch tracking or partial reconciliation -- any mismatch
///   abandons the *entire* pending queue at once.
/// `@unchecked Sendable`: `TerminalSessionController` (nonisolated, per
/// SwiftTerm's `TerminalViewDelegate` requirements) hops onto the main
/// actor via `Task { @MainActor in ... }` for every call into this type,
/// so all of its mutable state is in practice touched from one serialized
/// context, even though that isn't provable from the type alone.
final class MoshPredictionEngine: @unchecked Sendable {
    /// Bounds how far ahead of the last confirmed position predictions can
    /// run -- mostly a safety valve against runaway drift if something
    /// keeps going unconfirmed (e.g. typing into a no-echo password
    /// prompt), not a value mosh itself specifies.
    private static let maxPendingDepth = 20

    /// How many genuine mispredictions (see the type doc comment) to
    /// tolerate before giving up on prediction entirely for this engine's
    /// lifetime. Low on purpose: a program that's actually compatible with
    /// this engine's sequential-echo assumption essentially never mismatches
    /// during normal typing, so a handful of mismatches is already a
    /// reliable "this isn't working" signal, not noise to filter out.
    private static let mispredictionCircuitBreakerThreshold = 3

    private var pending: [UInt8] = []
    private var mispredictionCount = 0
    private var isDisabled = false

    /// Returns the bytes to feed the terminal, or `nil` if there's nothing
    /// to do. This is either an instant preview of `keystroke` (a single
    /// plain printable ASCII byte), or -- if `keystroke` isn't predictable,
    /// or the circuit breaker has tripped -- an erase instruction for any
    /// previously-drawn predictions that are being abandoned unconfirmed,
    /// so they never linger on screen (see the type doc comment).
    func predict(keystroke: [UInt8]) -> [UInt8]? {
        guard !isDisabled, keystroke.count == 1, let byte = keystroke.first, (0x20...0x7E).contains(byte) else {
            return abandonPending()
        }
        guard pending.count < Self.maxPendingDepth else { return nil }

        let offset = pending.count
        pending.append(byte)

        var bytes: [UInt8] = []
        if offset > 0 {
            // Skip forward over predictions already drawn (and reverted)
            // ahead of the true, unconfirmed cursor position.
            bytes += Array("\u{1B}[\(offset)C".utf8)
        }
        bytes += Array("\u{1B}[4m".utf8) // underline on
        bytes.append(byte)
        bytes += Array("\u{1B}[24m".utf8) // underline off (not a full SGR reset, so it doesn't disturb other active styling)
        bytes += Array("\u{1B}[\(offset + 1)D".utf8) // back to the true, unconfirmed cursor position
        return bytes
    }

    /// Observes real host bytes on their way to the terminal -- never
    /// modifies or suppresses them, only watches -- and returns bytes to
    /// erase any predictions abandoned as a result (`nil` if nothing needs
    /// erasing). Each plain printable byte that matches the front of the
    /// pending queue confirms that prediction (its real echo is what draws
    /// over the earlier preview, in exactly the same cell). Any mismatch,
    /// or any control/escape byte arriving while predictions are
    /// outstanding, is a genuine misprediction: it abandons the entire
    /// queue and counts toward the circuit breaker.
    func reconcile(hostBytes: [UInt8]) -> [UInt8]? {
        guard !pending.isEmpty else { return nil }
        for byte in hostBytes {
            guard !pending.isEmpty else { break }
            guard (0x20...0x7E).contains(byte), byte == pending[0] else {
                mispredictionCount += 1
                if mispredictionCount >= Self.mispredictionCircuitBreakerThreshold {
                    isDisabled = true
                }
                return abandonPending()
            }
            pending.removeFirst()
        }
        return nil
    }

    /// Drops any outstanding predictions, returning bytes to erase
    /// whatever was already drawn for them (`nil` if nothing was pending)
    /// -- callers use this when they know context has changed in a way
    /// this engine can't observe on its own (e.g. the terminal was just
    /// resized, or switched into/out of the alternate screen buffer).
    /// Doesn't count toward the circuit breaker: this is an external
    /// signal, not evidence prediction itself is failing against whatever
    /// program is running.
    func reset() -> [UInt8]? {
        abandonPending()
    }

    /// Erases exactly the cells still holding unconfirmed predictions
    /// (`CSI <n> X`, Erase Character -- blanks `n` cells at the cursor,
    /// which is still sitting at the true, unconfirmed base position,
    /// without moving it) and clears the pending queue. Returns `nil` if
    /// there was nothing pending, so callers can tell "nothing to feed"
    /// apart from "feed this empty-ish cleanup."
    private func abandonPending() -> [UInt8]? {
        guard !pending.isEmpty else { return nil }
        let count = pending.count
        pending.removeAll()
        return Array("\u{1B}[\(count)X".utf8)
    }
}
