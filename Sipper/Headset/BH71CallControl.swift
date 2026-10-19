import Foundation

/// The BH71's vendor telephony collection, report 4. Verified against the
/// connected 6993:b07e device's HID descriptor. No private display commands.
struct BH71Call: Equatable {
    enum Phase: String { case incoming, dialing, active, held }
    let id: Int
    var phase: Phase
    var muted: Bool
    var name = ""
    var number = ""
}

enum BH71Action: Equatable {
    case answer(Int), end(Int), reject(Int), mute(Int, Bool), hold(Int, Bool)
}

struct BH71CallControl {
    private(set) var previousInput: UInt8 = 0
    private(set) var calls: [BH71Call] = []
    private(set) var selectedID: Int?
    // Suppresses duplicate answer/end events while the SIP engine responds.
    private var pendingAction: BH71Action?

    var incoming: BH71Call? { calls.first { $0.phase == .incoming } }
    var current: BH71Call? {
        let connected = calls.filter { $0.phase != .incoming }
        return connected.first { $0.id == selectedID }
            ?? connected.first { $0.phase != .held } ?? connected.first
    }
    var output: UInt8 {
        var value: UInt8 = 0
        if let call = current {
            value |= 1
            if call.muted { value |= 2 }
            if call.phase == .held { value |= 8 }
        }
        if incoming != nil { value |= 4 }
        return value
    }

    mutating func synchronize(_ calls: [BH71Call], selectedID: Int?) {
        let oldCurrent = current
        if calls != self.calls { pendingAction = nil }
        self.calls = calls
        self.selectedID = selectedID
        // An app-originated answer/dial/resume also puts the device off-hook.
        // Ending it must work even if the device doesn't echo that output first.
        if let call = current, call.phase != .held,
           oldCurrent?.id != call.id || oldCurrent?.phase == .held {
            previousInput |= 1
        }
        if calls.isEmpty {
            previousInput = 0
            pendingAction = nil
        }
    }

    mutating func resetInput() {
        previousInput = current.map { $0.phase == .held ? 0 : 1 } ?? 0
        pendingAction = nil
    }

    static func inputValue(reportID: UInt32, bytes: [UInt8]) -> UInt8? {
        guard reportID == 4 else { return nil }
        // IOKit includes the report ID; two-byte payloads support test transports.
        if bytes.count == 3, bytes[0] == 4 { return bytes[1] }
        if bytes.count == 2 { return bytes[0] }
        return nil
    }

    mutating func receive(_ value: UInt8) -> BH71Action? {
        let changed = value ^ previousInput
        previousInput = value
        guard !calls.isEmpty, changed != 0 else { return nil }
        var action: BH71Action?
        if changed & 1 != 0 {
            if value & 1 != 0, let call = incoming, current == nil {
                action = .answer(call.id)
            } else if value & 1 == 0, let call = current {
                // An on-hook report may echo a hold; never hang up a held call.
                if call.phase != .held { action = .end(call.id) }
            }
        } else if changed & 4 != 0, value & 4 != 0, let call = current, call.phase == .active {
            // Mute is a relative button pulse, not an absolute mute state.
            action = .mute(call.id, !call.muted)
        } else if changed & 8 != 0, value & 8 != 0, let call = current {
            action = .hold(call.id, call.phase != .held)
        } else if changed & 0x40 != 0, value & 0x40 != 0, let call = incoming {
            action = .reject(call.id)
        }
        guard let action else { return nil }
        return accept(action)
    }

    // SDK touchscreen events and HID buttons can report the same operation.
    // Only changes relevant to the current SIP snapshot may be dispatched.
    mutating func accept(_ action: BH71Action) -> BH71Action? {
        switch action {
        case .answer(let id), .reject(let id):
            guard calls.contains(where: { $0.id == id && $0.phase == .incoming }) else { return nil }
        case .end(let id):
            guard calls.contains(where: { $0.id == id && $0.phase != .incoming }) else { return nil }
        case .mute(let id, let value):
            guard calls.contains(where: { $0.id == id && $0.phase == .active && $0.muted != value }) else { return nil }
        case .hold(let id, let value):
            guard calls.contains(where: { $0.id == id && ($0.phase == .active || $0.phase == .held) && ($0.phase == .held) != value }) else { return nil }
        }
        guard action != pendingAction else { return nil }
        pendingAction = action
        return action
    }
}
