import SwiftUI

struct BH71View: View {
    @ObservedObject var headset: BH71Controller

    var body: some View {
        Form {
            Section("BH71 Workstation") {
                Toggle("Enable headset call controls", isOn: $headset.enabled)
                Label(headset.status, systemImage: headset.connected ? "headphones" : "cable.connector")
                Text("Answer/end and mute synchronization use your workstation’s USB connection. Select the BH71 for call audio in Audio settings.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Hardware test") {
                Text("This test rings the workstation without placing a call or opening the microphone. Press the headset’s call button to answer, its mute button to toggle mute, then its call button to end. It stops automatically after two minutes.")
                    .font(.callout)
                HStack {
                    Button("Simulate Incoming Call") { headset.simulateIncoming() }
                        .disabled(!headset.connected || headset.hasLiveCalls || headset.demo != nil)
                    Button("Answer") { headset.answerDemo() }
                        .disabled(headset.demo?.phase != .incoming)
                    Button(headset.demo?.muted == true ? "Unmute" : "Mute") { headset.toggleDemoMute() }
                        .disabled(headset.demo?.phase != .active)
                    Button("End Test") { headset.endDemo() }.disabled(headset.demo == nil)
                }
                Text(demoLabel).fontWeight(.medium).accessibilityIdentifier("bh71-demo-state")
                Text(headset.callerIDStatus)
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Diagnostics") {
                LabeledContent("Last button report", value: headset.lastInput)
                LabeledContent("Last call state", value: headset.lastOutput)
                ScrollView {
                    Text(headset.events.suffix(12).joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }.frame(height: 100)
            }
        }.formStyle(.grouped).padding().frame(minWidth: 650, minHeight: 560)
    }

    private var demoLabel: String {
        guard let call = headset.demo else { return "Test idle" }
        switch call.phase {
        case .incoming: return "Test ringing — press the headset call button"
        case .active: return call.muted ? "Test active — muted" : "Test active — unmuted"
        case .held: return "Test held"
        case .dialing: return "Test dialing"
        }
    }
}

struct BH71Commands: Commands {
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandMenu("Headset") {
            Button("BH71 Workstation…") { openWindow(id: "bh71") }
                .keyboardShortcut("b", modifiers: [.command, .shift])
        }
    }
}
