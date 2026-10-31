import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func showSettings() {
        show(SettingsView(), size: NSSize(width: 560, height: 640), title: "DockBar Settings")
    }

    func showOnboarding() {
        show(PermissionsOnboardingView(), size: NSSize(width: 520, height: 420), title: "DockBar")
    }

    func close() {
        window?.close()
    }

    private func show<Content: View>(_ view: Content, size: NSSize, title: String) {
        NSApp.activate()
        let window = prepare(view, size: size, title: title)
        window.makeKeyAndOrderFront(nil)
    }

    func prepare<Content: View>(_ view: Content, size: NSSize, title: String) -> NSWindow {
        let window = ensureWindow()
        window.title = title
        window.contentView = NSHostingView(rootView: view)
        window.setContentSize(size)
        window.level = .normal
        window.center()
        if let screen = window.screen ?? NSScreen.main {
            var frame = window.frame
            let lowest = screen.visibleFrame.minY + TaskbarModel.shared.settings.occupiedHeight + 16
            if frame.minY < lowest {
                frame.origin.y = lowest
            }
            window.setFrame(frame, display: true)
        }
        return window
    }

    private func ensureWindow() -> NSWindow {
        if let window { return window }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        // Stay at the normal level so System Settings and permission prompts can appear in front.
        window.level = .normal
        self.window = window
        return window
    }

    /// Moves this window behind system permission prompts and System Settings.
    func yieldToSystemUI() {
        guard let window else { return }
        window.level = .normal
        DispatchQueue.main.async {
            window.orderBack(nil)
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first?
                .activate(from: .current, options: [])
        }
    }
}
