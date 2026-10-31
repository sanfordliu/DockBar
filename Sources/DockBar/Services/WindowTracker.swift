import AppKit
import CoreGraphics

enum WindowTracker {
    static func snapshot(allowedPIDs: Set<pid_t>) -> [CGWindowRecord] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) else {
            return []
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var records: [CGWindowRecord] = []
        for case let info as NSDictionary in list as NSArray {
            let layer = (info[kCGWindowLayer] as? NSNumber)?.intValue ?? 0
            guard layer == 0 else { continue }
            let alpha = (info[kCGWindowAlpha] as? NSNumber)?.doubleValue ?? 1
            guard alpha > 0.01 else { continue }
            guard let pid = (info[kCGWindowOwnerPID] as? NSNumber)?.int32Value else { continue }
            guard pid != ownPID, allowedPIDs.contains(pid) else { continue }
            guard
                let bounds = info[kCGWindowBounds] as? NSDictionary,
                let cgFrame = CGRect(dictionaryRepresentation: bounds)
            else { continue }
            guard cgFrame.width >= 24, cgFrame.height >= 24 else { continue }

            let appKitFrame = ScreenCoordinates.appKit(fromCGTopLeft: cgFrame)
            let onScreen = (info[kCGWindowIsOnscreen] as? NSNumber)?.boolValue ?? false
            let title = info[kCGWindowName] as? String ?? ""
            let windowID = (info[kCGWindowNumber] as? NSNumber)?.uint32Value ?? 0
            guard windowID != 0 else { continue }
            records.append(CGWindowRecord(
                windowID: windowID,
                ownerPID: pid,
                title: title,
                cgFrame: cgFrame,
                appKitFrame: appKitFrame,
                displayID: onScreen ? ScreenCoordinates.displayID(forAppKitRect: appKitFrame) : nil,
                isOnScreen: onScreen
            ))
        }
        return records
    }
}
