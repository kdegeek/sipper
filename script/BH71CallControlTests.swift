import Foundation

@main
struct BH71CallControlTests {
    static var checks = 0
    static func check(_ ok: @autoclosure () -> Bool, _ name: String) {
        guard ok() else { fatalError("FAILED: \(name)") }
        checks += 1
        print("PASS \(name)")
    }
    static func main() {
        var p = BH71CallControl()
        let incoming = BH71Call(id: 7, phase: .incoming, muted: false)
        var active = BH71Call(id: 7, phase: .active, muted: false)
        check(p.output == 0, "idle has no call flags")
        check(p.receive(1) == nil, "idle button cannot answer a nonexistent call")
        p.synchronize([], selectedID: nil)
        p.synchronize([incoming], selectedID: 7)
        check(p.output == 4, "incoming call rings workstation")
        check(p.receive(1) == .answer(7), "off-hook answers the ringing call")
        check(p.receive(1) == nil, "duplicate HID report does not answer twice")
        check(p.receive(0) == nil, "off-hook release while answering does not reject")
        check(p.receive(1) == nil, "pending answer ignores bouncing hook switch")
        p.synchronize([active], selectedID: 7)
        check(p.output == 1, "connected clears ringing and asserts off-hook")
        check(p.receive(5) == .mute(7, true), "mute press requests mute")
        check(p.receive(5) == nil, "held mute button does not toggle repeatedly")
        active.muted = true
        p.synchronize([active], selectedID: 7)
        check(p.output == 3, "app mute state is sent back to headset")
        check(p.receive(1) == nil, "mute button release does not unmute")
        check(p.receive(5) == .mute(7, false), "second mute press requests unmute")
        active.muted = false
        p.synchronize([active], selectedID: 7)
        check(p.output == 1, "app unmute clears device mute flag")
        _ = p.receive(1)
        check(p.receive(0) == .end(7), "on-hook ends the current call")
        check(p.receive(0) == nil, "duplicate on-hook does not end twice")
        p.synchronize([], selectedID: nil)
        check(p.output == 0, "remote end clears workstation flags")
        check(p.receive(4) == nil, "late mute report after remote end is harmless")

        p = BH71CallControl()
        p.synchronize([incoming], selectedID: 7)
        check(p.receive(0x40) == .reject(7), "reject pulse rejects incoming call")
        p.synchronize([], selectedID: nil)
        p.synchronize([active], selectedID: 7)
        _ = p.receive(1)
        check(p.receive(9) == .hold(7, true), "flash requests hold")
        active.phase = .held
        p.synchronize([active], selectedID: 7)
        check(p.output == 9, "hold flag reaches workstation")
        check(p.receive(0) == nil, "hold on-hook echo must not hang up")
        check(p.receive(8) == .hold(7, false), "flash resumes held call")

        p = BH71CallControl()
        active.phase = .active
        let waiting = BH71Call(id: 8, phase: .incoming, muted: false)
        p.synchronize([active, waiting], selectedID: 8)
        check(p.output == 5, "waiting call preserves active off-hook state")
        check(p.receive(1) == nil, "waiting call cannot steal a connected call")
        check(p.receive(0) == .end(7), "end targets current call not waiting call")
        p.synchronize([waiting], selectedID: 8)
        check(p.receive(1) == .answer(8), "remaining ringing call can be answered")
        p.resetInput()
        check(p.receive(1) == .answer(8), "reconnect resets stale button state")

        p = BH71CallControl()
        p.synchronize([incoming], selectedID: 7)
        p.synchronize([active], selectedID: 7)
        check(p.receive(0) == .end(7), "hardware end works after answering in app without a hook echo")
        p = BH71CallControl()
        p.synchronize([BH71Call(id: 9, phase: .dialing, muted: false)], selectedID: 9)
        check(p.receive(0) == .end(9), "hardware end cancels app-originated dialing")
        p.synchronize([active], selectedID: 7)
        p.resetInput()
        check(p.receive(0) == .end(7), "hardware end works after reconnecting during a call")

        p = BH71CallControl()
        p.synchronize([incoming], selectedID: 7)
        check(p.accept(.answer(7)) == .answer(7), "SDK screen answer dispatches to SIP")
        check(p.receive(1) == nil, "HID mirror does not duplicate SDK answer")
        p.synchronize([active], selectedID: 7)
        check(p.accept(.answer(7)) == nil, "SDK answer echo after connection ignored")
        check(p.receive(5) == .mute(7, true), "HID mute dispatches before SDK mirror")
        check(p.accept(.mute(7, true)) == nil, "SDK mirror does not duplicate HID mute")
        active.muted = true
        p.synchronize([active], selectedID: 7)
        check(p.accept(.mute(7, true)) == nil, "mute feedback cannot toggle it back")
        check(p.accept(.end(999)) == nil, "stale SDK call ID ignored")
        check(p.accept(.mute(7, false)) == .mute(7, false), "SDK screen unmute dispatches exact state")

        check(BH71CallControl.inputValue(reportID: 4, bytes: [4, 5, 0]) == 5, "IOKit report ID is removed")
        check(BH71CallControl.inputValue(reportID: 4, bytes: [5, 0]) == 5, "payload-only test transport is decoded")
        check(BH71CallControl.inputValue(reportID: 2, bytes: [2, 1, 0]) == nil, "standard mirror report ignored to avoid double events")
        check(BH71CallControl.inputValue(reportID: 0xc8, bytes: [0xc8, 1, 0]) == nil, "vendor management traffic ignored")
        check(BH71CallControl.inputValue(reportID: 4, bytes: []) == nil, "truncated report ignored")
        check(BH71CallControl.inputValue(reportID: 4, bytes: [9, 1, 0]) == nil, "mismatched report header ignored")
        print("\(checks) BH71 call-control checks passed")
    }
}
