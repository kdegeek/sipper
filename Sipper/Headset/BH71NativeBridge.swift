import Foundation

/// Native ARM64 USB caller-ID helper, isolated from the UI and SIP engine.
/// Private child-process pipes carry call metadata. No listener, credentials or call logs.
@MainActor
final class BH71NativeBridge {
    var onReady: ((Bool) -> Void)?
    var onAction: ((BH71Action) -> Void)?
    var onDiagnostic: ((String) -> Void)?
    private(set) var ready = false
    private var process: Process?
    private var input: FileHandle?
    private var generation = UUID()
    private var lastCalls: [BH71Call]?
    private let writer = DispatchQueue(label: "Sipper.BH71NativeBridge.writer")

    func start() {
        guard process == nil else { return }
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/BH71NativeBridge")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            onDiagnostic?("Caller ID helper is not bundled; USB button controls remain available")
            return
        }
        let child = Process(), incoming = Pipe(), outgoing = Pipe()
        child.executableURL = executable
        child.standardInput = incoming
        child.standardOutput = outgoing
        child.standardError = FileHandle.nullDevice
        let token = UUID()
        generation = token
        child.terminationHandler = { [weak self] process in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.process = nil; self.input = nil; self.lastCalls = nil
                self.ready = false; self.onReady?(false)
                self.onDiagnostic?("Caller ID helper stopped (\(process.terminationStatus)); using USB call controls")
            }
        }
        do {
            try child.run()
            process = child
            input = incoming.fileHandleForWriting
            onDiagnostic?("Starting native BH71 caller ID…")
            let reader = outgoing.fileHandleForReading
            DispatchQueue.global(qos: .utility).async { [weak self] in
                var pending = Data()
                while true {
                    let data = reader.availableData
                    if data.isEmpty { break }
                    pending.append(data)
                    if pending.count > 65536 { break }
                    while let newline = pending.firstIndex(of: 10) {
                        let line = pending.prefix(upTo: newline)
                        pending.removeSubrange(...newline)
                        guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                        Task { @MainActor [weak self] in
                            guard let self, self.generation == token else { return }
                            self.receive(event)
                        }
                    }
                }
                try? reader.close()
            }
        } catch {
            onDiagnostic?("Caller ID helper could not start: \(error.localizedDescription).")
        }
    }

    private func receive(_ event: [String: Any]) {
        switch event["event"] as? String {
        case "ready":
            ready = event["ready"] as? Bool ?? false
            lastCalls = nil
            onReady?(ready)
            onDiagnostic?(ready ? "Caller ID connected — native Apple Silicon" : "Caller ID waiting for BH71 reconnection")
        case "action":
            guard let id = event["id"] as? Int, let action = event["action"] as? Int else { return }
            switch action {
            case 1: onAction?(.answer(id))
            case 2: onAction?(.end(id))
            case 3: onAction?(.hold(id, true))
            case 4: onAction?(.hold(id, false))
            case 5: onAction?(.reject(id))
            case 8: onAction?(.mute(id, true))
            case 9: onAction?(.mute(id, false))
            default: break
            }
        case "error":
            let operation = event["operation"] as? String ?? "operation"
            let code = event["code"] as? Int ?? -1
            lastCalls = nil
            onDiagnostic?("BH71 caller ID \(operation) failed (\(code))")
        default: break
        }
    }

    func synchronize(_ calls: [BH71Call]) {
        guard ready, calls != lastCalls else { return }
        let values: [[String: Any]] = calls.map { call in
            ["id": call.id, "phase": call.phase.rawValue, "muted": call.muted,
             "name": String(call.name.replacingOccurrences(of: "\0", with: "").prefix(128)),
             "number": String(call.number.replacingOccurrences(of: "\0", with: "").prefix(128))]
        }
        send(["command": "sync", "calls": values])
        lastCalls = calls
    }

    private func send(_ object: [String: Any]) {
        guard let handle = input, var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(10)
        writer.async { try? handle.write(contentsOf: data) }
    }

    func stop() {
        guard let child = process else { return }
        send(["command": "quit"])
        let handle = input
        writer.async { try? handle?.close() }
        generation = UUID()
        ready = false; process = nil; input = nil; lastCalls = nil
        // EOF normally cleans up immediately; bound shutdown for a stuck USB transport.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            if child.isRunning { child.terminate() }
        }
    }
}
