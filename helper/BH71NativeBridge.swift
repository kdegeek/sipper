import Foundation
import IOKit.hid

private struct Call: Equatable {
    let id: Int
    let phase: UInt8
    let muted: Bool
    let name: String
    let number: String
    init?(_ value: [String: Any]) {
        guard let id = value["id"] as? Int, let phase = value["phase"] as? String,
              let mapped = ["incoming": UInt8(5), "active": 1, "held": 2, "dialing": 4][phase] else { return nil }
        self.id = id; self.phase = mapped; muted = value["muted"] as? Bool ?? false
        name = value["name"] as? String ?? ""; number = value["number"] as? String ?? ""
    }
}
private struct MappedCall {
    let cid: UInt16
    let incoming: Bool
    var call: Call
}
private struct Failure: Error {
    let operation: String
    let code: Int
}

/// Native USB transport in a private child process, with no vendor library or network access.
/// All mutable USB/state data is owned by the main run loop. Stdin only enqueues snapshots.
private final class Bridge {
    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
    private var device: IOHIDDevice?
    private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024)
    private var tag: UInt16 = 0
    private var expected: (UInt16, UInt16)?
    private var reply: [UInt8]?
    private var session: UInt16 = 0
    private var availableIDs: [UInt16] = []
    private var calls: [Int: MappedCall] = [:]
    private var desired: [Call] = []
    private var dirty = false
    private var quitting = false
    private var removed = false
    private var nextConnect = Date.distantPast
    private var heartbeat = Date.distantPast

    private func emit(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(10)
        try? FileHandle.standardOutput.write(contentsOf: data)
    }
    private func receive(_ id: UInt32, _ data: [UInt8]) {
        // Event 0x41 carries a call ACTION, not the display-state phase enum.
        // IDs are scoped to this session; Sipper validates and deduplicates actions.
        if id == 0xc8, let event = BH71Protocol.callEvent(data), event.session == session,
           let mapped = calls.values.first(where: { $0.cid == event.cid }) {
            emit(["event": "action", "id": mapped.call.id, "action": Int(event.action)])
            return
        }
        guard id == 0xc8, data.count >= 20, data[0] == 0xc8, data[1] == 0x13,
              let (command, tag) = expected,
              BH71Protocol.word(data, 4) == command, BH71Protocol.word(data, 6) == tag else { return }
        reply = data
    }
    private func request(_ command: UInt16, _ a: UInt32 = 0, _ b: UInt32 = 0,
                         _ payload: [UInt8] = [], minimum: Int = 20, checkStatus: Bool = true, waitForReply: Bool = true) throws -> [UInt8] {
        guard let device, !removed else { throw Failure(operation: "disconnected", code: -1) }
        tag &+= 1
        let packet = BH71Protocol.packet(command: command, tag: tag, a: a, b: b, payload: payload)!
        expected = (command, tag); reply = nil
        defer { expected = nil; reply = nil }
        let result = packet.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0xc8, $0.baseAddress!, $0.count)
        }
        let operation = String(format: "USB %04x", command)
        guard result == kIOReturnSuccess else { throw Failure(operation: operation, code: Int(result)) }
        if !waitForReply { return [] }
        let deadline = Date().addingTimeInterval(1)
        while reply == nil && !removed && Date() < deadline {
            CFRunLoopRunInMode(.defaultMode, 0.01, true)
        }
        guard let reply, reply.count >= minimum else { throw Failure(operation: operation, code: -2) }
        let status = BH71Protocol.integer(reply, 12)
        guard !checkStatus || status == 0 else { throw Failure(operation: operation, code: Int(status)) }
        return reply
    }
    private func connect() throws {
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, let candidate = devices.first else { return }
        guard IOHIDDeviceOpen(candidate, 0) == kIOReturnSuccess else { throw Failure(operation: "open", code: -1) }
        device = candidate; removed = false
        IOHIDDeviceRegisterInputReportCallback(candidate, buffer, 1024, { context, result, _, _, id, bytes, count in
            guard result == kIOReturnSuccess, let context, count > 0 else { return }
            Unmanaged<Bridge>.fromOpaque(context).takeUnretainedValue().receive(id, Array(UnsafeBufferPointer(start: bytes, count: count)))
        }, Unmanaged.passUnretained(self).toOpaque())
        let registration = try request(0x276, 1, 0, BH71Protocol.identity)
        let identifier = BH71Protocol.integer(registration, 16)
        guard identifier > 0 && identifier <= UInt16.max else { throw Failure(operation: "session", code: -1) }
        session = UInt16(identifier)
        try allocateIDs()
        _ = try request(0x239, 1, UInt32(ProcessInfo.processInfo.processIdentifier))
        heartbeat = Date().addingTimeInterval(3)
        dirty = !desired.isEmpty
        emit(["event": "ready", "ready": true])
    }
    private func allocateIDs() throws {
        let response = try request(0x283, UInt32(session), 50, minimum: 24)
        let first = BH71Protocol.word(response, 20), last = BH71Protocol.word(response, 22)
        guard first > 0, last >= first, Int(last) - Int(first) < 50 else { throw Failure(operation: "call IDs", code: -1) }
        availableIDs = Array(first...last).reversed()
    }
    private func state(_ mapped: MappedCall, phase: UInt8? = nil) throws {
        let target = phase ?? mapped.call.phase
        _ = try request(0x285, UInt32(session), UInt32(mapped.cid),
                        BH71Protocol.state(session: session, cid: mapped.cid, phase: target,
                                           muted: mapped.call.muted, incoming: mapped.incoming))
        // Readback is stronger than a write ACK, and also matches the observed SDK sequence.
        let response = try request(0x286, UInt32(session), UInt32(mapped.cid), minimum: 28)
        guard response[24] == (target == 6 ? 0 : target),
              target == 6 || response[26] == (mapped.call.muted ? 1 : 0) else {
            throw Failure(operation: "state readback", code: -1)
        }
    }
    private func synchronize(_ snapshot: [Call]) throws {
        let retained = Set(snapshot.map(\.id))
        for id in calls.keys.sorted() where !retained.contains(id) {
            try state(calls[id]!, phase: 6)
            calls.removeValue(forKey: id)
        }
        for call in snapshot {
            let old = calls[call.id]
            if old?.call == call { continue }
            var mapped: MappedCall
            if let old { mapped = old; mapped.call = call }
            else {
                if availableIDs.isEmpty { try allocateIDs() }
                mapped = MappedCall(cid: availableIDs.removeLast(), incoming: call.phase == 5, call: call)
            }
            // Track the allocated ID before writing, so failure cleanup can terminate it.
            calls[call.id] = mapped
            if call.phase == 1 && (old?.call.muted ?? false) != call.muted {
                // Call-state mute updates the screen; the virtual key also updates headset mute.
                _ = try request(0x237, 0, call.muted ? 8 : 9, waitForReply: false)
            }
            try state(mapped)
            if old == nil || old?.call.name != call.name || old?.call.number != call.number {
                _ = try request(0x22c, 4, UInt32(mapped.cid), BH71Protocol.contact(name: call.name, number: call.number))
            }
        }
        emit(["event": "synced", "count": snapshot.count])
    }
    private func disconnect() {
        if session != 0 && !removed {
            // Stop on the first transport failure, keeping shutdown bounded.
            do {
                for mapped in calls.values { try state(mapped, phase: 6) }
                _ = try request(0x239, 0, UInt32(ProcessInfo.processInfo.processIdentifier))
                _ = try request(0x277, 0, UInt32(session), checkStatus: false)
                _ = try request(0x276, 0, UInt32(session), BH71Protocol.identity)
            } catch { }
        }
        if let device {
            IOHIDDeviceRegisterInputReportCallback(device, buffer, 1024, nil, nil)
            IOHIDDeviceClose(device, 0)
        }
        device = nil; session = 0; calls.removeAll(); availableIDs.removeAll()
        emit(["event": "ready", "ready": false])
        nextConnect = Date().addingTimeInterval(3)
    }
    private func command(_ object: [String: Any]) {
        switch object["command"] as? String {
        case "quit": quitting = true
        case "sync":
            guard let values = object["calls"] as? [[String: Any]], values.count <= 50 else { return }
            let parsed = values.compactMap(Call.init)
            guard parsed.count == values.count, Set(parsed.map(\.id)).count == parsed.count else { return }
            desired = parsed; dirty = true
        default: break
        }
    }
    func run() {
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x6993, kIOHIDProductIDKey: 0xb07e,
                                               kIOHIDPrimaryUsagePageKey: 0xb, kIOHIDPrimaryUsageKey: 5] as CFDictionary)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, candidate in
            guard let context else { return }
            let owner = Unmanaged<Bridge>.fromOpaque(context).takeUnretainedValue()
            if let device = owner.device, CFEqual(device, candidate) { owner.removed = true }
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        guard IOHIDManagerOpen(manager, 0) == kIOReturnSuccess else {
            emit(["event": "error", "operation": "USB manager", "code": -1]); return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            while let line = readLine() {
                guard line.utf8.count < 65536, let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                DispatchQueue.main.async { self?.command(object) }
            }
            DispatchQueue.main.async { self?.quitting = true }
        }
        while !quitting {
            CFRunLoopRunInMode(.defaultMode, 0.02, true)
            do {
                if removed && device != nil { disconnect() }
                if device == nil && Date() >= nextConnect { nextConnect = Date().addingTimeInterval(3); try connect() }
                guard session != 0, !quitting else { continue }
                if dirty {
                    dirty = false
                    let snapshot = desired
                    try synchronize(snapshot)
                }
                if Date() >= heartbeat {
                    _ = try request(0x277, 1, UInt32(session), checkStatus: false)
                    heartbeat = Date().addingTimeInterval(3)
                }
            } catch {
                let failure = error as? Failure
                emit(["event": "error", "operation": failure?.operation ?? "USB", "code": failure?.code ?? -1])
                disconnect()
            }
        }
        disconnect()
        IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager, 0)
        buffer.deallocate()
    }
}

@main
private enum Main {
    static func main() { Bridge().run() }
}
