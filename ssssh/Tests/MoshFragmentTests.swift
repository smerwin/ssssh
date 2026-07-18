import Foundation
import Testing
@testable import ssssh

struct MoshFragmentTests {
    @Test("Fragment header round-trips through serialize/parse")
    func headerRoundTrips() throws {
        let fragment = MoshFragment(id: 0x0102030405060708, fragmentNum: 0x1234, final: true, contents: [0xAA, 0xBB])
        let parsed = try MoshFragment.parse(fragment.serialize())
        #expect(parsed.id == fragment.id)
        #expect(parsed.fragmentNum == fragment.fragmentNum)
        #expect(parsed.final == fragment.final)
        #expect(parsed.contents == fragment.contents)
    }

    @Test("Final bit and fragment number pack into the same 2 bytes without colliding")
    func finalBitDoesNotCollideWithFragmentNumber() throws {
        let maxFragmentNum: UInt16 = 0x7FFF
        let fragment = MoshFragment(id: 1, fragmentNum: maxFragmentNum, final: false, contents: [])
        let parsed = try MoshFragment.parse(fragment.serialize())
        #expect(parsed.fragmentNum == maxFragmentNum)
        #expect(parsed.final == false)
    }

    @Test("A small instruction fits in a single fragment")
    func smallInstructionIsOneFragment() throws {
        var instruction = MoshTransportInstruction()
        instruction.oldNum = 0
        instruction.newNum = 1
        instruction.diff = Array("hello".utf8)

        let fragmenter = MoshFragmenter()
        let fragments = try fragmenter.makeFragments(for: instruction, mtu: 500)
        #expect(fragments.count == 1)
        #expect(fragments[0].final == true)
        #expect(fragments[0].fragmentNum == 0)

        let assembly = MoshFragmentAssembly()
        #expect(assembly.addFragment(fragments[0]) == true)
        let reassembled = try assembly.takeAssembly()
        #expect(reassembled.oldNum == 0)
        #expect(reassembled.newNum == 1)
        #expect(reassembled.diff == Array("hello".utf8))
    }

    @Test("A large instruction splits across multiple fragments and reassembles correctly")
    func largeInstructionSplitsAndReassembles() throws {
        var instruction = MoshTransportInstruction()
        instruction.oldNum = 3
        instruction.newNum = 4
        instruction.ackNum = 2
        // Random-ish incompressible content so it doesn't shrink back under
        // one fragment after zlib compression.
        instruction.diff = (0..<5000).map { UInt8(($0 * 2654435761) & 0xFF) }

        let fragmenter = MoshFragmenter()
        let fragments = try fragmenter.makeFragments(for: instruction, mtu: 200)
        #expect(fragments.count > 1)
        #expect(fragments.dropLast().allSatisfy { !$0.final })
        #expect(fragments.last!.final)
        #expect(Set(fragments.map(\.id)).count == 1)

        let assembly = MoshFragmentAssembly()
        var complete = false
        // Feed fragments in reverse to prove reassembly doesn't depend on
        // arrival order, matching UDP's lack of ordering guarantees.
        for fragment in fragments.reversed() {
            complete = assembly.addFragment(fragment)
        }
        #expect(complete)
        let reassembled = try assembly.takeAssembly()
        #expect(reassembled.oldNum == 3)
        #expect(reassembled.newNum == 4)
        #expect(reassembled.ackNum == 2)
        #expect(reassembled.diff == instruction.diff)
    }

    @Test("A resent instruction with identical sequencing fields reuses the same fragment id")
    func identicalSequencingReusesFragmentID() throws {
        var instruction = MoshTransportInstruction()
        instruction.oldNum = 0
        instruction.newNum = 1
        instruction.diff = Array("first".utf8)

        let fragmenter = MoshFragmenter()
        let first = try fragmenter.makeFragments(for: instruction, mtu: 500)

        instruction.diff = Array("first".utf8) // same old_num/new_num/ack_num/throwaway_num/chaff
        let second = try fragmenter.makeFragments(for: instruction, mtu: 500)

        #expect(first[0].id == second[0].id)
    }

    @Test("A genuinely new instruction gets a fresh fragment id")
    func newInstructionGetsFreshFragmentID() throws {
        var instruction = MoshTransportInstruction()
        instruction.oldNum = 0
        instruction.newNum = 1
        instruction.diff = Array("first".utf8)

        let fragmenter = MoshFragmenter()
        let first = try fragmenter.makeFragments(for: instruction, mtu: 500)

        instruction.newNum = 2
        instruction.diff = Array("second".utf8)
        let second = try fragmenter.makeFragments(for: instruction, mtu: 500)

        #expect(first[0].id != second[0].id)
    }
}
