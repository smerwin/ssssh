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
/// naturally overwrites the same cell. That means confirmation needs no
/// special handling at all: real bytes are never suppressed, delayed, or
/// rewritten, they just draw over the prediction in place, in order.
///
/// Deliberate simplifications versus real mosh, all in the direction of
/// "never wrong, sometimes less helpful":
/// - Only predicts a single, plain printable ASCII byte (0x20-0x7E) sent
///   on its own -- not Enter, Backspace, arrow keys, or anything
///   multi-byte (real mosh predicts some of these too, under stricter
///   rules). Anything else clears any outstanding predictions rather than
///   risk guessing wrong about cursor motion this app doesn't model.
/// - No SRTT-adaptive show/hide -- predictions always render (underlined)
///   as soon as the caller decides it's safe to ask (see
///   `TerminalSessionController`'s alternate-screen-buffer check).
/// - No glitch/epoch tracking. On any sign of trouble -- a real byte that
///   doesn't match the front of the pending queue, or a control/escape
///   byte arriving while predictions are outstanding -- this abandons the
///   whole pending queue rather than attempting partial reconciliation.
///   In that rare case, an already-drawn underlined prediction can be left
///   on screen until something else overwrites that cell: a real, known
///   cosmetic limitation, not a correctness one -- the underlying terminal
///   content itself is never at risk, since real bytes are never dropped
///   or altered, only observed.
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

    private var pending: [UInt8] = []

    /// Returns the bytes to feed the terminal as an instant local preview
    /// of `keystroke`, or `nil` if this input isn't a simple printable
    /// keystroke and shouldn't be predicted (which also abandons any
    /// currently-pending predictions, since this app can no longer be
    /// confident the pending queue's assumed cursor position is right).
    func predict(keystroke: [UInt8]) -> [UInt8]? {
        guard keystroke.count == 1, let byte = keystroke.first, (0x20...0x7E).contains(byte) else {
            pending.removeAll()
            return nil
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
    /// modifies or suppresses them, only watches. Each plain printable
    /// byte that matches the front of the pending queue confirms that
    /// prediction (its real echo is what draws over the earlier preview,
    /// in exactly the same cell). Any mismatch, or any control/escape byte
    /// arriving while predictions are outstanding, abandons the entire
    /// queue rather than guessing at partial reconciliation.
    func reconcile(hostBytes: [UInt8]) {
        guard !pending.isEmpty else { return }
        for byte in hostBytes {
            guard !pending.isEmpty else { break }
            guard (0x20...0x7E).contains(byte), byte == pending[0] else {
                pending.removeAll()
                return
            }
            pending.removeFirst()
        }
    }

    /// Drops any outstanding predictions without inspecting them --
    /// callers use this when they know context has changed in a way this
    /// engine can't observe on its own (e.g. the terminal was just
    /// resized, or switched into/out of the alternate screen buffer).
    func reset() {
        pending.removeAll()
    }
}
