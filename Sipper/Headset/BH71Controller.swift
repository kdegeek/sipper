import Foundation
import Combine
import IOKit.hid

/// Main-run-loop IOKit owner. Opens the telephony interface without seizing it.
/// Report 4 handles buttons; the native helper handles temporary caller-ID sessions.
@MainActor
final class BH71Controller: ObservableObject {
    @Published var enabled = false {
        didSet {
            guard enabled != oldValue else { return }
            UserDefaults.standard.set(enabled, forKey: "BH71CallControlEnabled")
            if enabled { start() } else { stop() }
        }
    }
    @Published private(set) var status = "Disabled"
    @Published private(set) var connected = false
    @Published private(set) var events: [String] = []
    @Published private(set) var demo: BH71Call?
    @Published private(set) var lastInput = "No button reports yet"
    @Published private(set) var lastOutput = "No call state sent"
    @Published private(set) var hasLiveCalls = false
    @Published private(set) var callerIDStatus = "Caller ID disabled"

    var onAction: ((BH71Action) -> Void)?
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private let inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024)
    private var policy = BH71CallControl()
    private var liveCalls: [BH71Call] = []
    private var selectedID: Int?
    private var sentOutput: UInt8?
    private var ownsCallState = false
    private var demoTimeout: DispatchWorkItem?
    private let callerID = BH71NativeBridge()

    init() {
        callerID.onDiagnostic = { [weak self] message in
            self?.callerIDStatus = message
            self?.record(message)
        }
        callerID.onReady = { [weak self] ready in
            guard let self else { return }
            self.sentOutput = nil
            if ready { self.ownsCallState = false }
            self.sendState()
        }
        callerID.onAction = { [weak self] action in
            guard let self, let accepted = self.policy.accept(action) else { return }
            self.dispatch(accepted)
        }
    }

    func restorePreference() {
        enabled = UserDefaults.standard.bool(forKey: "BH71CallControlEnabled")
    }

    func synchronize(_ calls: [BH71Call], selectedID: Int?) {
        liveCalls = calls
        self.selectedID = selectedID
        hasLiveCalls = !calls.isEmpty
        if !calls.isEmpty { demo = nil; demoTimeout?.cancel() }
        updatePolicy()
    }

    func simulateIncoming() {
        guard connected, !hasLiveCalls else { return }
        demo = BH71Call(id: -7100, phase: .incoming, muted: false,
                        name: "Sipper Caller ID Test", number: "7100")
        record("Synthetic incoming call (no SIP call or microphone)")
        updatePolicy()
        demoTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in self?.endDemo() }
        demoTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: timeout)
    }

    func answerDemo() {
        guard var call = demo, call.phase == .incoming else { return }
        call.phase = .active
        demo = call
        record("Synthetic call answered")
        updatePolicy()
    }

    func toggleDemoMute() {
        guard var call = demo, call.phase == .active else { return }
        call.muted.toggle()
        demo = call
        record(call.muted ? "Synthetic call muted" : "Synthetic call unmuted")
        updatePolicy()
    }

    func endDemo() {
        guard demo != nil else { return }
        demo = nil
        demoTimeout?.cancel()
        record("Synthetic call ended")
        updatePolicy()
    }

    private func updatePolicy() {
        policy.synchronize(demo.map { [$0] } ?? liveCalls, selectedID: selectedID)
        sendState()
    }

    private func record(_ text: String) {
        events.append(text)
        if events.count > 30 { events.removeFirst(events.count - 30) }
        NSLog("BH71: %@", text)
    }

    private func start() {
        guard manager == nil else { return }
        policy.synchronize(demo.map { [$0] } ?? liveCalls, selectedID: selectedID)
        status = "Looking for BH71 Workstation…"
        callerID.start()
        let hid = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = hid
        IOHIDManagerSetDeviceMatching(hid, [
            kIOHIDVendorIDKey: 0x6993,
            kIOHIDProductIDKey: 0xb07e,
            kIOHIDPrimaryUsagePageKey: 0x0b,
            kIOHIDPrimaryUsageKey: 5
        ] as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(hid, { context, _, _, device in
            guard let context else { return }
            // Manager callbacks are scheduled on the main run loop below.
            MainActor.assumeIsolated {
                Unmanaged<BH71Controller>.fromOpaque(context).takeUnretainedValue().attach(device)
            }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(hid, { context, _, _, device in
            guard let context else { return }
            MainActor.assumeIsolated {
                Unmanaged<BH71Controller>.fromOpaque(context).takeUnretainedValue().removed(device)
            }
        }, context)
        IOHIDManagerScheduleWithRunLoop(hid, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(hid, IOOptionBits(kIOHIDOptionsTypeNone))
        if result != kIOReturnSuccess {
            status = "USB access failed (\(result))"
            record(status)
        }
    }

    private func attach(_ candidate: IOHIDDevice) {
        guard device == nil else { return }
        // Restrict writes to the inspected report layout, not all Yealink products.
        let elements = IOHIDDeviceCopyMatchingElements(candidate, nil, 0) as? [IOHIDElement] ?? []
        guard elements.contains(where: {
            IOHIDElementGetReportID($0) == 4 && IOHIDElementGetType($0) == kIOHIDElementTypeOutput
        }) else { status = "BH71 has an unsupported report layout"; return }
        let result = IOHIDDeviceOpen(candidate, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            status = "BH71 is unavailable (\(result))"
            record(status)
            return
        }
        device = candidate
        sentOutput = nil
        policy.resetInput()
        connected = true
        status = "BH71 Workstation connected"
        record(status)
        IOHIDDeviceRegisterInputReportCallback(candidate, inputBuffer, 1024, { context, result, _, _, reportID, bytes, count in
            guard result == kIOReturnSuccess, let context, count > 0 else { return }
            let data = Array(UnsafeBufferPointer(start: bytes, count: count))
            MainActor.assumeIsolated {
                Unmanaged<BH71Controller>.fromOpaque(context).takeUnretainedValue().receive(reportID, data)
            }
        }, Unmanaged.passUnretained(self).toOpaque())
        sendState()
    }

    private func removed(_ removedDevice: IOHIDDevice) {
        guard let device, CFEqual(device, removedDevice) else { return }
        IOHIDDeviceRegisterInputReportCallback(device, inputBuffer, 1024, nil, nil)
        IOHIDDeviceClose(device, 0)
        self.device = nil
        connected = false
        sentOutput = nil
        ownsCallState = false
        policy.resetInput()
        status = "BH71 disconnected; waiting to reconnect"
        record(status)
    }

    private func receive(_ reportID: UInt32, _ bytes: [UInt8]) {
        guard let value = BH71CallControl.inputValue(reportID: reportID, bytes: bytes) else { return }
        lastInput = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        guard let action = policy.receive(value) else { return }
        dispatch(action)
    }

    private func dispatch(_ action: BH71Action) {
        record("Button: \(action)")
        if var call = demo {
            switch action {
            case .answer: answerDemo()
            case .end, .reject: endDemo()
            case .mute(_, let value): call.muted = value; demo = call; updatePolicy()
            case .hold(_, let value): call.phase = value ? .held : .active; demo = call; updatePolicy()
            }
        } else {
            onAction?(action)
        }
    }

    private func sendState() {
        if callerID.ready {
            callerID.synchronize(policy.calls)
            lastOutput = "Native BH71: \(policy.calls.count) call(s)"
            return
        }
        guard let device else { return }
        // Don't reset another app's headset state just by opening our test app.
        guard !policy.calls.isEmpty || ownsCallState else { return }
        let value = policy.output
        guard value != sentOutput else { return }
        let bytes: [UInt8] = [4, value]
        let result = bytes.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 4, $0.baseAddress!, $0.count)
        }
        if result == kIOReturnSuccess {
            sentOutput = value
            ownsCallState = !policy.calls.isEmpty
            lastOutput = String(format: "Report 04: %02X", value)
            record(lastOutput)
        } else {
            status = "Could not send BH71 call state (\(result))"
            record(status)
        }
    }

    func stop() {
        callerID.stop()
        callerIDStatus = "Caller ID disabled"
        demoTimeout?.cancel()
        demo = nil
        if ownsCallState { policy.synchronize([], selectedID: nil); sendState() }
        if let device {
            IOHIDDeviceRegisterInputReportCallback(device, inputBuffer, 1024, nil, nil)
            IOHIDDeviceClose(device, 0)
        }
        device = nil
        if let manager {
            IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
            IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager, 0)
        }
        manager = nil
        connected = false
        ownsCallState = false
        sentOutput = nil
        policy.resetInput()
        status = "Disabled"
    }

    deinit { inputBuffer.deallocate() }
}
