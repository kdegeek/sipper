import Foundation

/// Observed BH71 6993:b07e report-C8 protocol. All integers are little endian.
/// Packets are constructed from fields; captured padding is never replayed.
enum BH71Protocol {
    static func word(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }
    static func integer(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(word(bytes, offset)) | UInt32(word(bytes, offset + 2)) << 16
    }
    static func put(_ value: UInt32, into bytes: inout [UInt8], at offset: Int, width: Int = 4) {
        for index in 0..<width { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
    }
    static func string(_ value: String, into bytes: inout [UInt8], at offset: Int, capacity: Int) {
        // Preserve UTF-8 character boundaries and reserve a terminating NUL.
        var data = Array(value.replacingOccurrences(of: "\0", with: "").utf8.prefix(capacity - 1))
        while String(bytes: data, encoding: .utf8) == nil { data.removeLast() }
        bytes.replaceSubrange(offset..<offset + data.count, with: data)
    }
    static func packet(command: UInt16, tag: UInt16, a: UInt32, b: UInt32, payload: [UInt8]) -> [UInt8]? {
        guard payload.count <= 1004 else { return nil }
        var bytes = [UInt8](repeating: 0, count: 1024)
        bytes[0] = 0xc8; bytes[1] = 0x13
        put(UInt32(16 + payload.count), into: &bytes, at: 2, width: 2)
        put(UInt32(command), into: &bytes, at: 4, width: 2)
        put(UInt32(tag), into: &bytes, at: 6, width: 2)
        put(UInt32(payload.count), into: &bytes, at: 8)
        put(a, into: &bytes, at: 12); put(b, into: &bytes, at: 16)
        bytes.replaceSubrange(20..<20 + payload.count, with: payload)
        return bytes
    }
    static func callEvent(_ bytes: [UInt8]) -> (session: UInt16, cid: UInt16, action: UInt16)? {
        guard bytes.count >= 62, bytes[0] == 0xc8, bytes[1] == 0x3b,
              word(bytes, 4) == 0x41, word(bytes, 6) == 54 else { return nil }
        let action = word(bytes, 12)
        guard [1, 2, 3, 4, 5, 8, 9].contains(action) else { return nil }
        return (word(bytes, 8), word(bytes, 10), action)
    }
    static var identity: [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 160)
        string("Sipper", into: &bytes, at: 0, capacity: 32)
        string("v1", into: &bytes, at: 32, capacity: 4)
        bytes[36] = 1
        return bytes
    }
    static func state(session: UInt16, cid: UInt16, phase: UInt8, muted: Bool, incoming: Bool) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 54)
        put(UInt32(session), into: &bytes, at: 0, width: 2)
        put(UInt32(cid), into: &bytes, at: 2, width: 2)
        bytes[4] = phase; bytes[6] = muted ? 1 : 0; bytes[7] = incoming ? 2 : 1
        return bytes
    }
    static func contact(name: String, number: String) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 300)
        string(name, into: &bytes, at: 0, capacity: 200)
        string(number, into: &bytes, at: 200, capacity: 100)
        return bytes
    }
}
