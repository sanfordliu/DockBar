import CoreGraphics
import Foundation

/// Chromium profile highlight, stored as opaque RGB. Chrome writes this as an SkColor.
struct ProfileTint: Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
}

struct WindowInfo: Identifiable, Equatable, Sendable {
    var id: CGWindowID { windowID }
    var windowID: CGWindowID
    var ownerPID: pid_t
    var title: String
    /// Window frame in AppKit coordinates (origin at the bottom left of the primary display).
    var frame: CGRect
    /// Window frame in Core Graphics coordinates (origin at the top left of the primary display).
    var cgFrame: CGRect
    var displayID: CGDirectDisplayID?
    var isMinimized: Bool
    var isOnScreen: Bool
    /// Browser profile this window belongs to, when the app has more than one.
    var profileName: String? = nil
    /// Color chosen for that profile in Chrome or another Chromium browser.
    var profileTint: ProfileTint? = nil
}

struct CGWindowRecord: Sendable {
    var windowID: CGWindowID
    var ownerPID: pid_t
    var title: String
    var cgFrame: CGRect
    var appKitFrame: CGRect
    var displayID: CGDirectDisplayID?
    var isOnScreen: Bool

    func asWindowInfo(minimized: Bool = false) -> WindowInfo {
        WindowInfo(
            windowID: windowID,
            ownerPID: ownerPID,
            title: title,
            frame: appKitFrame,
            cgFrame: cgFrame,
            displayID: displayID,
            isMinimized: minimized,
            isOnScreen: isOnScreen && !minimized
        )
    }
}
