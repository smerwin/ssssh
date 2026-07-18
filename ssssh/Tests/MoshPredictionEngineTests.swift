import Foundation
import Testing
@testable import ssssh

struct MoshPredictionEngineTests {
    @Test("Predicts a first printable byte with no forward skip, underlined, then reverts the cursor")
    func predictsFirstByte() {
        let engine = MoshPredictionEngine()
        let result = engine.predict(keystroke: [0x61]) // "a"
        let expected: [UInt8] = Array("\u{1B}[4ma\u{1B}[24m\u{1B}[1D".utf8)
        #expect(result == expected)
    }

    @Test("Predicts a second pending byte by skipping forward over the first, then reverting past both")
    func predictsSecondByte() {
        let engine = MoshPredictionEngine()
        _ = engine.predict(keystroke: [0x61]) // "a"
        let result = engine.predict(keystroke: [0x62]) // "b"
        let expected: [UInt8] = Array("\u{1B}[1C\u{1B}[4mb\u{1B}[24m\u{1B}[2D".utf8)
        #expect(result == expected)
    }

    @Test("Refuses to predict multi-byte input and erases the one pending prediction")
    func refusesMultiByteInput() {
        let engine = MoshPredictionEngine()
        _ = engine.predict(keystroke: [0x61]) // one pending prediction
        let result = engine.predict(keystroke: [0x1B, 0x5B, 0x41]) // an arrow key escape sequence
        #expect(result == Array("\u{1B}[1X".utf8)) // erase the 1 cell that was pending

        // Confirm the queue is now actually empty -- the next prediction
        // starts fresh at offset 0, not appended after a stale entry.
        let next = engine.predict(keystroke: [0x63]) // "c"
        #expect(next == Array("\u{1B}[4mc\u{1B}[24m\u{1B}[1D".utf8))
    }

    @Test("Refuses to predict non-printable single bytes (e.g. Enter, Backspace) and returns nil when nothing was pending")
    func refusesNonPrintableSingleByte() {
        let engine = MoshPredictionEngine()
        #expect(engine.predict(keystroke: [0x0D]) == nil) // Enter
        #expect(engine.predict(keystroke: [0x7F]) == nil) // Backspace/DEL
    }

    @Test("Caps pending depth so runaway unconfirmed predictions stop, not grow forever")
    func capsPendingDepth() {
        let engine = MoshPredictionEngine()
        var lastNonNilCount = 0
        for i in 0..<30 {
            let byte = UInt8(0x61 + (i % 20))
            if engine.predict(keystroke: [byte]) != nil {
                lastNonNilCount += 1
            }
        }
        #expect(lastNonNilCount == 20) // MoshPredictionEngine.maxPendingDepth
    }

    @Test("Reconcile consumes matching real bytes from the front of the pending queue")
    func reconcileConsumesMatches() {
        let engine = MoshPredictionEngine()
        _ = engine.predict(keystroke: [0x61]) // "a"
        _ = engine.predict(keystroke: [0x62]) // "b"

        let cleanup = engine.reconcile(hostBytes: [0x61]) // confirms "a"
        #expect(cleanup == nil) // a full match needs no erasing

        // "c" should now predict as if only "b" is still outstanding --
        // i.e. at offset 1, not offset 2.
        let result = engine.predict(keystroke: [0x63])
        let expected: [UInt8] = Array("\u{1B}[1C\u{1B}[4mc\u{1B}[24m\u{1B}[2D".utf8)
        #expect(result == expected)
    }

    @Test("Reconcile abandons the whole queue on a mismatched byte and returns an erase instruction")
    func reconcileAbandonsOnMismatch() {
        let engine = MoshPredictionEngine()
        _ = engine.predict(keystroke: [0x61]) // predicted "a"
        let cleanup = engine.reconcile(hostBytes: [0x78]) // but the real echo is "x" (e.g. autocorrect/completion)
        #expect(cleanup == Array("\u{1B}[1X".utf8))

        // Queue should be empty now -- the next prediction starts fresh at offset 0.
        let result = engine.predict(keystroke: [0x63])
        #expect(result == Array("\u{1B}[4mc\u{1B}[24m\u{1B}[1D".utf8))
    }

    @Test("Reconcile abandons the queue if a control/escape byte arrives while predictions are outstanding")
    func reconcileAbandonsOnControlByte() {
        let engine = MoshPredictionEngine()
        _ = engine.predict(keystroke: [0x61])
        let cleanup = engine.reconcile(hostBytes: [0x1B]) // an escape sequence starting, not plain text
        #expect(cleanup == Array("\u{1B}[1X".utf8))

        let result = engine.predict(keystroke: [0x63])
        #expect(result == Array("\u{1B}[4mc\u{1B}[24m\u{1B}[1D".utf8))
    }

    @Test("Reconcile is a no-op when nothing is pending")
    func reconcileNoOpWhenEmpty() {
        let engine = MoshPredictionEngine()
        #expect(engine.reconcile(hostBytes: Array("hello world, nothing pending here".utf8)) == nil)
        let result = engine.predict(keystroke: [0x61])
        #expect(result == Array("\u{1B}[4ma\u{1B}[24m\u{1B}[1D".utf8))
    }

    @Test("reset() erases outstanding predictions and clears them")
    func resetClearsPending() {
        let engine = MoshPredictionEngine()
        _ = engine.predict(keystroke: [0x61])
        _ = engine.predict(keystroke: [0x62])
        let cleanup = engine.reset()
        #expect(cleanup == Array("\u{1B}[2X".utf8)) // two pending cells to erase

        let result = engine.predict(keystroke: [0x63])
        #expect(result == Array("\u{1B}[4mc\u{1B}[24m\u{1B}[1D".utf8))
    }

    @Test("reset() returns nil when nothing was pending")
    func resetNoOpWhenEmpty() {
        let engine = MoshPredictionEngine()
        #expect(engine.reset() == nil)
    }

    @Test("A multi-character sequence reconciles correctly end to end, matching real echo byte for byte")
    func endToEndReconciliation() {
        let engine = MoshPredictionEngine()
        let word = Array("echo".utf8)
        for byte in word {
            _ = engine.predict(keystroke: [byte])
        }
        // The real server echoes the same bytes back, arriving as one chunk.
        #expect(engine.reconcile(hostBytes: word) == nil)

        // Fully confirmed -- next prediction should start fresh at offset 0.
        let result = engine.predict(keystroke: [0x20]) // space
        #expect(result == Array("\u{1B}[4m \u{1B}[24m\u{1B}[1D".utf8))
    }

    // MARK: - Circuit breaker (the real bug: raw-mode apps like Claude Code's
    // own CLI redraw their input box with absolute cursor positioning
    // instead of echoing sequentially, so most predictions mismatch)

    @Test("Trips after repeated genuine mispredictions and stops predicting")
    func circuitBreakerTripsOnRepeatedMispredictions() {
        let engine = MoshPredictionEngine()

        // Two mismatches shouldn't be enough on their own (threshold is 3).
        for _ in 0..<2 {
            #expect(engine.predict(keystroke: [0x61]) != nil)
            #expect(engine.reconcile(hostBytes: [0x1B]) != nil) // mismatch: a control byte instead
        }
        #expect(engine.predict(keystroke: [0x61]) != nil) // still working

        // Third genuine misprediction trips the breaker.
        #expect(engine.reconcile(hostBytes: [0x1B]) != nil)

        // From here on, predict() should never produce a preview again --
        // only possibly an erase for whatever was still pending (nothing
        // is, here, since the mismatch above already cleared it).
        #expect(engine.predict(keystroke: [0x62]) == nil)
        #expect(engine.predict(keystroke: [0x63]) == nil)
    }

    @Test("Deliberately not predicting Enter/Backspace does not count toward the circuit breaker")
    func nonPredictableKeystrokesDoNotTripBreaker() {
        let engine = MoshPredictionEngine()

        // Simulate lots of normal shell usage: type, confirm, hit Enter --
        // repeated many times, well past the mismatch threshold, with only
        // *expected* non-predictions (Enter) and no genuine mismatches.
        for _ in 0..<10 {
            _ = engine.predict(keystroke: [0x61])
            #expect(engine.reconcile(hostBytes: [0x61]) == nil) // confirmed correctly
            _ = engine.predict(keystroke: [0x0D]) // Enter -- deliberately not predicted
        }

        // Prediction should still work fine -- the breaker never tripped.
        let result = engine.predict(keystroke: [0x62])
        #expect(result == Array("\u{1B}[4mb\u{1B}[24m\u{1B}[1D".utf8))
    }
}
