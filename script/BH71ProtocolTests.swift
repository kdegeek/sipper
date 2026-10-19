import Foundation

@main enum Tests {
    static func main() {
        // Independently captured envelope: registration opcode 0x276, 160-byte identity.
        let packet = BH71Protocol.packet(command: 0x276, tag: 0x1234, a: 1, b: 0, payload: BH71Protocol.identity)!
        precondition(Array(packet.prefix(20)) == [0xc8,0x13,0xb0,0,0x76,2,0x34,0x12,0xa0,0,0,0,1,0,0,0,0,0,0,0])
        precondition(packet.count == 1024 && packet.dropFirst(180).allSatisfy { $0 == 0 })
        precondition(BH71Protocol.packet(command: 0, tag: 0, a: 0, b: 0, payload: Array(repeating: 1, count: 1005)) == nil)
        let state = BH71Protocol.state(session: 0x2715, cid: 0x4bca, phase: 5, muted: false, incoming: true)
        precondition(Array(state.prefix(8)) == [0x15,0x27,0xca,0x4b,5,0,0,2])
        precondition(state.count == 54 && state.dropFirst(8).allSatisfy { $0 == 0 })
        let contact = BH71Protocol.contact(name: String(repeating: "🙂", count: 100), number: "71\0" + String(repeating: "é", count: 100))
        precondition(contact.count == 300 && contact[199] == 0 && contact[299] == 0)
        let name = contact[0..<200].prefix { $0 != 0 }, number = contact[200..<300].prefix { $0 != 0 }
        precondition(String(bytes: name, encoding: .utf8) == String(repeating: "🙂", count: 49))
        precondition(String(bytes: number, encoding: .utf8) == "71" + String(repeating: "é", count: 48))
        // Empty contact is entirely deterministic; no capture padding or process memory leaks.
        precondition(BH71Protocol.contact(name: "", number: "").allSatisfy { $0 == 0 })
        var event = [UInt8](repeating: 0, count: 62)
        event.replaceSubrange(0..<16, with: [0xc8,0x3b,4,2,0x41,0,0x36,0,0x15,0x27,0x92,0x4c,1,0,1,0])
        let parsed = BH71Protocol.callEvent(event)!
        precondition(parsed.session == 10005 && parsed.cid == 19602 && parsed.action == 1)
        precondition(BH71Protocol.callEvent(Array(event.prefix(61))) == nil)
        for action: UInt8 in [1, 2, 3, 4, 5, 8, 9] {
            event[12] = action
            precondition(BH71Protocol.callEvent(event)?.action == UInt16(action))
        }
        event[12] = 6 // Display phase 6 is ended; it is NOT an allowed input action.
        precondition(BH71Protocol.callEvent(event) == nil)
        event[4] = 0x48
        precondition(BH71Protocol.callEvent(event) == nil)
        print("PASS native call-event framing, session, call ID, action decoding")
        print("PASS native protocol envelope, bounds, call state, zero padding, UTF-8 and NUL handling")
    }
}
