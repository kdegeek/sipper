import SwiftUI

struct SipperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window(BuildIdentity.name, id: "main") {
            MainWindow()
                .environmentObject(appDelegate.state)
                .frame(minWidth: 820, minHeight: 520)
        }
        .defaultSize(width: 1000, height: 660)
        .commands {
            SipperCommands(state: appDelegate.state)
            BH71Commands()
        }

        Window("BH71 Workstation", id: "bh71") {
            BH71View(headset: appDelegate.state.headset)
        }
        .defaultSize(width: 700, height: 600)

        Settings {
            SettingsView()
                .environmentObject(appDelegate.state)
        }
    }
}
