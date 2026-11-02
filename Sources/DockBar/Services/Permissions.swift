import AppKit
import ApplicationServices
import CoreGraphics

enum Permissions {
    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    static func promptAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    static var isScreenCaptureGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func requestScreenCapture() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    enum ScreenCaptureStep: Equatable {
        case requestAccess
        case openSettings
    }

    /// The first click asks macOS. A later click opens Settings once access is still missing.
    static func screenCaptureStep(alreadyPrompted: Bool, granted: Bool) -> ScreenCaptureStep? {
        if granted { return nil }
        return alreadyPrompted ? .openSettings : .requestAccess
    }

    static func openPrivacyPane(_ anchor: String) {
        let modern = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(anchor)")
        let legacy = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
        if let modern {
            NSWorkspace.shared.open(modern)
        } else if let legacy {
            NSWorkspace.shared.open(legacy)
        }
    }
}
