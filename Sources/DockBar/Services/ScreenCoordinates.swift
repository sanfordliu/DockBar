import AppKit

extension NSScreen {
    var displayID: CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (deviceDescription[key] as? NSNumber)?.uint32Value ?? 0
    }
}

enum ScreenCoordinates {
    private static let heightLock = NSLock()
    nonisolated(unsafe) private static var cachedPrimaryHeight: CGFloat = 0

    static var hasPrimaryScreen: Bool {
        NSScreen.screens.contains { $0.frame.origin == .zero }
    }

    /// Uses the AppKit primary display. When that screen is missing during a display change,
    /// the last known height stays in place so stacked displays do not shift every window.
    static func resolvedPrimaryHeight(originZeroHeight: CGFloat?, cached: CGFloat) -> CGFloat {
        if let originZeroHeight, originZeroHeight > 0 { return originZeroHeight }
        return cached
    }

    static var primaryHeight: CGFloat {
        heightLock.lock()
        defer { heightLock.unlock() }
        let height = resolvedPrimaryHeight(
            originZeroHeight: NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height,
            cached: cachedPrimaryHeight
        )
        if hasPrimaryScreen {
            cachedPrimaryHeight = height
        }
        return height
    }

    static func appKit(fromCGTopLeft rect: CGRect) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: primaryHeight - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    static func cgTopLeft(fromAppKit rect: CGRect) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: primaryHeight - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    static func roughlyEqual(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 10) -> Bool {
        abs(a.origin.x - b.origin.x) < tolerance
            && abs(a.origin.y - b.origin.y) < tolerance
            && abs(a.width - b.width) < tolerance
            && abs(a.height - b.height) < tolerance
    }

    static func displayID(forAppKitRect rect: CGRect) -> CGDirectDisplayID? {
        var best: (CGDirectDisplayID, CGFloat)?
        for screen in NSScreen.screens {
            let area = screen.frame.intersection(rect)
            guard !area.isNull, !area.isEmpty else { continue }
            let value = area.width * area.height
            if value > (best?.1 ?? 0) {
                best = (screen.displayID, value)
            }
        }
        if let best { return best.0 }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        return NSScreen.screens.first { $0.frame.contains(center) }?.displayID
    }

    static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { $0.displayID == displayID }
    }
}
