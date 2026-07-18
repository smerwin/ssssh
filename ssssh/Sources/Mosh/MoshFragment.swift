import Foundation

/// Mirrors mosh's `Network::Fragment`/`FragmentAssembly`/`Fragmenter`
/// (`src/network/transportfragment.{h,cc}`): a `MoshTransportInstruction`
/// is zlib-compressed, then split across one or more UDP datagrams if it
/// doesn't fit in one, each prefixed with an 8-byte big-endian fragment-set
/// id and a 2-byte big-endian fragment number whose top bit marks the
/// final fragment in the set.
struct MoshFragment {
    static let headerLength = 8 + 2

    let id: UInt64
    let fragmentNum: UInt16
    let final: Bool
    let contents: [UInt8]

    func serialize() -> [UInt8] {
        precondition(fragmentNum & 0x8000 == 0, "fragment_num must fit in 15 bits")
        var bytes = Self.bigEndianBytes64(id)
        let combined: UInt16 = (final ? 0x8000 : 0) | fragmentNum
        bytes.append(contentsOf: Self.bigEndianBytes16(combined))
        bytes.append(contentsOf: contents)
        return bytes
    }

    struct ParseError: Error {}

    static func parse(_ data: [UInt8]) throws -> MoshFragment {
        guard data.count >= headerLength else { throw ParseError() }
        let id = bigEndianValue64(Array(data.prefix(8)))
        let combined = bigEndianValue16(Array(data[8..<10]))
        return MoshFragment(
            id: id,
            fragmentNum: combined & 0x7FFF,
            final: (combined & 0x8000) != 0,
            contents: Array(data.dropFirst(headerLength))
        )
    }

    private static func bigEndianBytes64(_ value: UInt64) -> [UInt8] {
        (0..<8).map { UInt8(truncatingIfNeeded: value >> (56 - $0 * 8)) }
    }

    private static func bigEndianValue64(_ bytes: [UInt8]) -> UInt64 {
        bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    private static func bigEndianBytes16(_ value: UInt16) -> [UInt8] {
        [UInt8(value >> 8), UInt8(value & 0xFF)]
    }

    private static func bigEndianValue16(_ bytes: [UInt8]) -> UInt16 {
        (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
    }
}

/// Reassembles a stream of `MoshFragment`s (which may arrive out of order,
/// per UDP) back into one `MoshTransportInstruction`, mirroring
/// `FragmentAssembly::add_fragment`/`get_assembly`.
final class MoshFragmentAssembly {
    private var fragments: [MoshFragment?] = []
    private var currentID: UInt64?
    private var fragmentsArrived = 0
    private var fragmentsTotal: Int?

    /// Returns `true` once every fragment of the current set has arrived;
    /// call `takeAssembly()` next to consume and decode it.
    func addFragment(_ fragment: MoshFragment) -> Bool {
        let index = Int(fragment.fragmentNum)

        if currentID != fragment.id {
            fragments = [MoshFragment?](repeating: nil, count: index + 1)
            fragments[index] = fragment
            fragmentsArrived = 1
            fragmentsTotal = nil
            currentID = fragment.id
        } else if index < fragments.count, fragments[index] != nil {
            // Duplicate delivery of a fragment we already have -- ignore.
        } else {
            if fragments.count < index + 1 {
                fragments.append(contentsOf: [MoshFragment?](repeating: nil, count: index + 1 - fragments.count))
            }
            fragments[index] = fragment
            fragmentsArrived += 1
        }

        if fragment.final {
            let total = index + 1
            fragmentsTotal = total
            if fragments.count < total {
                fragments.append(contentsOf: [MoshFragment?](repeating: nil, count: total - fragments.count))
            }
        }

        return fragmentsTotal != nil && fragmentsArrived == fragmentsTotal
    }

    struct IncompleteAssembly: Error {}

    /// Concatenates, decompresses, and parses the now-complete fragment
    /// set. Only call after `addFragment` has returned `true`; resets
    /// internal state afterward so this instance is ready for the next
    /// fragment set.
    func takeAssembly() throws -> MoshTransportInstruction {
        var encoded: [UInt8] = []
        for fragment in fragments {
            guard let fragment else { throw IncompleteAssembly() }
            encoded.append(contentsOf: fragment.contents)
        }

        fragments = []
        fragmentsArrived = 0
        fragmentsTotal = nil
        currentID = nil

        return try MoshTransportInstruction.parse(MoshCompression.uncompress(encoded))
    }
}

/// Splits an outgoing `MoshTransportInstruction` into `MoshFragment`s that
/// fit within `mtu`, mirroring `Fragmenter::make_fragments`. Each
/// genuinely new instruction (one whose sequencing fields differ from the
/// last one fragmented) gets a fresh fragment-set id.
final class MoshFragmenter {
    private var nextInstructionID: UInt64 = 0
    private var lastInstruction: MoshTransportInstruction?
    private var lastEffectiveMTU: Int = -1

    func makeFragments(for instruction: MoshTransportInstruction, mtu: Int) throws -> [MoshFragment] {
        let effectiveMTU = mtu - MoshFragment.headerLength
        precondition(effectiveMTU > 0)

        if isNewContent(instruction, effectiveMTU: effectiveMTU) {
            nextInstructionID += 1
        }
        lastInstruction = instruction
        lastEffectiveMTU = effectiveMTU

        let payload = try MoshCompression.compress(instruction.serialize())
        var fragments: [MoshFragment] = []
        var fragmentNum: UInt16 = 0
        var remaining = payload[...]
        repeat {
            let chunkSize = min(effectiveMTU, remaining.count)
            let chunk = Array(remaining.prefix(chunkSize))
            remaining = remaining.dropFirst(chunkSize)
            fragments.append(MoshFragment(id: nextInstructionID, fragmentNum: fragmentNum, final: remaining.isEmpty, contents: chunk))
            fragmentNum += 1
        } while !remaining.isEmpty
        return fragments
    }

    private func isNewContent(_ instruction: MoshTransportInstruction, effectiveMTU: Int) -> Bool {
        guard let last = lastInstruction, lastEffectiveMTU == effectiveMTU else { return true }
        return instruction.oldNum != last.oldNum
            || instruction.newNum != last.newNum
            || instruction.ackNum != last.ackNum
            || instruction.throwawayNum != last.throwawayNum
            || instruction.chaff != last.chaff
    }
}
