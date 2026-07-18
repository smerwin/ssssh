import Foundation
import Testing
@testable import ssssh

struct MoshMessagesTests {
    // MARK: - TransportBuffers.Instruction

    @Test("Instruction encoding matches a hand-computed protobuf byte sequence")
    func instructionMatchesHandComputedBytes() {
        var instruction = MoshTransportInstruction()
        instruction.oldNum = 5
        instruction.newNum = 6
        instruction.diff = [0x41, 0x42] // "AB"

        // field1 (protocol_version=2): tag 0x08, value 0x02
        // field2 (old_num=5):          tag 0x10, value 0x05
        // field3 (new_num=6):          tag 0x18, value 0x06
        // field6 (diff="AB"):          tag 0x32, len 0x02, bytes 41 42
        // ack_num/throwaway_num/chaff are all zero/empty -> omitted
        let expected: [UInt8] = [0x08, 0x02, 0x10, 0x05, 0x18, 0x06, 0x32, 0x02, 0x41, 0x42]
        #expect(instruction.serialize() == expected)
    }

    @Test("Instruction round-trips through serialize/parse")
    func instructionRoundTrips() throws {
        var instruction = MoshTransportInstruction()
        instruction.oldNum = 12
        instruction.newNum = 13
        instruction.ackNum = 11
        instruction.throwawayNum = 10
        instruction.diff = Array("some diff bytes".utf8)
        instruction.chaff = [0x01, 0x02, 0x03]

        let parsed = try MoshTransportInstruction.parse(instruction.serialize())
        #expect(parsed.oldNum == 12)
        #expect(parsed.newNum == 13)
        #expect(parsed.ackNum == 11)
        #expect(parsed.throwawayNum == 10)
        #expect(parsed.diff == Array("some diff bytes".utf8))
        #expect(parsed.chaff == [0x01, 0x02, 0x03])
    }

    @Test("Instruction round-trips all-zero/empty fields (proto2 default vs. omitted are indistinguishable)")
    func instructionRoundTripsDefaults() throws {
        let instruction = MoshTransportInstruction()
        let parsed = try MoshTransportInstruction.parse(instruction.serialize())
        #expect(parsed.oldNum == 0)
        #expect(parsed.newNum == 0)
        #expect(parsed.ackNum == 0)
        #expect(parsed.throwawayNum == 0)
        #expect(parsed.diff == [])
    }

    // MARK: - ClientBuffers.UserMessage (what the client sends)

    @Test("A single keystroke instruction matches a hand-computed protobuf byte sequence")
    func keystrokeMatchesHandComputedBytes() {
        let message = MoshUserMessage(instructions: [.keystroke([0x61])]) // "a"

        // Keystroke.keys (field4="a"):        22 01 61
        // Instruction.keystroke (field2=that): 12 03 22 01 61
        // UserMessage.instruction (field1=that): 0A 05 12 03 22 01 61
        let expected: [UInt8] = [0x0A, 0x05, 0x12, 0x03, 0x22, 0x01, 0x61]
        #expect(message.serialize() == expected)
    }

    @Test("A resize instruction matches a hand-computed protobuf byte sequence")
    func resizeMatchesHandComputedBytes() {
        let message = MoshUserMessage(instructions: [.resize(width: 80, height: 24)])

        // ResizeMessage.width (field5=80):  28 50
        // ResizeMessage.height (field6=24): 30 18
        // Instruction.resize (field3=that): 1A 04 28 50 30 18
        // UserMessage.instruction (field1=that): 0A 06 1A 04 28 50 30 18
        let expected: [UInt8] = [0x0A, 0x06, 0x1A, 0x04, 0x28, 0x50, 0x30, 0x18]
        #expect(message.serialize() == expected)
    }

    @Test("Multiple keystroke instructions serialize independently and concatenate")
    func multipleInstructionsSerialize() {
        let message = MoshUserMessage(instructions: [.keystroke([0x61]), .keystroke([0x62])])
        let single = MoshUserMessage(instructions: [.keystroke([0x61])]).serialize()
        let single2 = MoshUserMessage(instructions: [.keystroke([0x62])]).serialize()
        #expect(message.serialize() == single + single2)
    }

    // MARK: - HostBuffers.HostMessage (what the server sends)

    @Test("Parses a hand-constructed HostBytes instruction")
    func parsesHostBytesInstruction() throws {
        // HostBytes.hoststring (field4="hi\n"): 22 03 68 69 0A
        // Instruction.hostbytes (field2=that):  12 05 22 03 68 69 0A
        // HostMessage.instruction (field1=that): 0A 07 12 05 22 03 68 69 0A
        let bytes: [UInt8] = [0x0A, 0x07, 0x12, 0x05, 0x22, 0x03, 0x68, 0x69, 0x0A]
        let message = try MoshHostMessage.parse(bytes)
        #expect(message.instructions.count == 1)
        guard case .hostBytes(let host) = message.instructions[0] else {
            Issue.record("expected .hostBytes")
            return
        }
        #expect(host == [0x68, 0x69, 0x0A])
    }

    @Test("Parses a hand-constructed EchoAck instruction")
    func parsesEchoAckInstruction() throws {
        // EchoAck.echo_ack_num (field8=42): 40 2A
        // Instruction.echoack (field7=that): 3A 02 40 2A
        // HostMessage.instruction (field1=that): 0A 04 3A 02 40 2A
        let bytes: [UInt8] = [0x0A, 0x04, 0x3A, 0x02, 0x40, 0x2A]
        let message = try MoshHostMessage.parse(bytes)
        #expect(message.instructions.count == 1)
        guard case .echoAck(let num) = message.instructions[0] else {
            Issue.record("expected .echoAck")
            return
        }
        #expect(num == 42)
    }

    @Test("Parses a HostMessage containing multiple instructions")
    func parsesMultipleHostInstructions() throws {
        let hostBytesInst: [UInt8] = [0x0A, 0x07, 0x12, 0x05, 0x22, 0x03, 0x68, 0x69, 0x0A]
        let echoAckInst: [UInt8] = [0x0A, 0x04, 0x3A, 0x02, 0x40, 0x2A]
        let message = try MoshHostMessage.parse(hostBytesInst + echoAckInst)
        #expect(message.instructions.count == 2)
    }

    @Test("Parses an empty HostMessage as zero instructions")
    func parsesEmptyHostMessage() throws {
        let message = try MoshHostMessage.parse([])
        #expect(message.instructions.isEmpty)
    }
}
