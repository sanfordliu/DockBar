import AppKit
import SwiftUI

@main
struct DockBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("DockBar", systemImage: "dock.rectangle") {
            Button("Settings…") {
                SettingsWindowController.shared.showSettings()
            }
            Button("Permissions…") {
                SettingsWindowController.shared.showOnboarding()
            }
            Divider()
            Button("Quit and Restore Dock") {
                NSApp.terminate(nil)
            }
        }
        .menuBarExtraStyle(.menu)
    }
}
