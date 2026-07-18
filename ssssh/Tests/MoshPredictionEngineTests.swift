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

    @Test("Refuses to predict multi-byte input and clears any pending predictions")
    func refusesMultiByteInput() {
        let engine = MoshPredictionEngine()
        _ = engine.predict(keystroke: [0x61])
        let result = engine.predict(keystroke: [0x1B, 0x5B, 0x41]) // an arrow key escape sequence
        #expect(result == nil)

        // The pending queue should now be empty -- confirm indirectly: a
        // control byte no longer has anything to reconcile against, so it
        // must not clear again (reconcile is a no-op on an empty queue,
        // observable via a following prediction starting fresh at offset 0).
        let next = engine.predict(keystroke: [0x63]) // "c"
        #expect(next == Array("\u{1B}[4mc\u{1B}[24m\u{1B}[1D".utf8))
    }

    @Test("Refuses to predict non-printable single bytes (e.g. Enter, Backspace)")
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

        engine.reconcile(hostBytes: [0x61]) // confirms "a"

        // "c" should now predict as if only "b" is still outstanding --
        // i.e. at offset 1, not offset 2.
        let result = engine.predict(keystroke: [0x63])
        let expected: [UInt8] = Array("\u{1B}[1C\u{1B}[4mc\u{1B}[24m\u{1B}[2D".utf8)
        #expect(result == expected)
    }

    @Test("Reconcile abandons the whole queue on a mismatched byte")
    func reconcileAbandonsOnMismatch() {
        let engine = MoshPredictionEngine()
        _ = engine.predict(keystroke: [0x61]) // predicted "a"
        engine.reconcile(hostBytes: [0x78]) // but the real echo is "x" (e.g. autocorrect/completion)

        // Queue should be empty now -- the next prediction starts fresh at offset 0.
        let result = engine.predict(keystroke: [0x63])
        #expect(result == Array("\u{1B}[4mc\u{1B}[24m\u{1B}[1D".utf8))
    }

    @Test("Reconcile abandons the queue if a control/escape byte arrives while predictions are outstanding")
    func reconcileAbandonsOnControlByte() {
        let engine = MoshPredictionEngine()
        _ = engine.predict(keystroke: [0x61])
        engine.reconcile(hostBytes: [0x1B]) // an escape sequence starting, not plain text

        let result = engine.predict(keystroke: [0x63])
        #expect(result == Array("\u{1B}[4mc\u{1B}[24m\u{1B}[1D".utf8))
    }

    @Test("Reconcile is a no-op when nothing is pending")
    func reconcileNoOpWhenEmpty() {
        let engine = MoshPredictionEngine()
        engine.reconcile(hostBytes: Array("hello world, nothing pending here".utf8))
        let result = engine.predict(keystroke: [0x61])
        #expect(result == Array("\u{1B}[4ma\u{1B}[24m\u{1B}[1D".utf8))
    }

    @Test("reset() clears outstanding predictions")
    func resetClearsPending() {
        let engine = MoshPredictionEngine()
        _ = engine.predict(keystroke: [0x61])
        _ = engine.predict(keystroke: [0x62])
        engine.reset()

        let result = engine.predict(keystroke: [0x63])
        #expect(result == Array("\u{1B}[4mc\u{1B}[24m\u{1B}[1D".utf8))
    }

    @Test("A multi-character sequence reconciles correctly end to end, matching real echo byte for byte")
    func endToEndReconciliation() {
        let engine = MoshPredictionEngine()
        let word = Array("echo".utf8)
        for byte in word {
            _ = engine.predict(keystroke: [byte])
        }
        // The real server echoes the same bytes back, arriving as one chunk.
        engine.reconcile(hostBytes: word)

        // Fully confirmed -- next prediction should start fresh at offset 0.
        let result = engine.predict(keystroke: [0x20]) // space
        #expect(result == Array("\u{1B}[4m \u{1B}[24m\u{1B}[1D".utf8))
    }
}
