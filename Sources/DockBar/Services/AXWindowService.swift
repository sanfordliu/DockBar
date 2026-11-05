import AppKit
import ApplicationServices
import Foundation

final class AXElementBox: @unchecked Sendable {
    let element: AXUIElement
    init(_ element: AXUIElement) { self.element = element }
}

private final class AXHub: @unchecked Sendable {
    static let shared = AXHub()

    func handle(notification: String, element: AXElementBox) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if notification == kAXUIElementDestroyedNotification as String {
                    AXWindowService.shared.forgetDestroyed(element.element)
                }
                AXWindowService.shared.scheduleRefresh()
            }
        }
    }
}

private func axObserverCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    AXHub.shared.handle(notification: notification as String, element: AXElementBox(element))
}

@MainActor
final class AXWindowService {
    static let shared = AXWindowService()

    /// Tests set this to false. Production leaves it on.
    /// While false, nothing here changes a real window, app, or accessibility observer.
    static var systemChangesAllowed = true

    private var observers: [pid_t: AXObserver] = [:]
    private var observedWindows: [CGWindowID: pid_t] = [:]
    private var elements: [CGWindowID: AXUIElement] = [:]
    private var elementPID: [CGWindowID: pid_t] = [:]
    private var lastDisplay: [CGWindowID: CGDirectDisplayID] = [:]
    private var backoffUntil: [pid_t: Date] = [:]
    private var fittedAt: [CGWindowID: Date] = [:]
    private var fitStrikes: [CGWindowID: (count: Int, at: Date)] = [:]
    private var refreshTask: Task<Void, Never>?
    /// Windows we asked to minimize. Kept until AX reports minimized so a mid-animation
    /// refresh cannot drop them from the bar (CG already off-screen, AX not yet updated).
    private var pendingMinimized: Set<CGWindowID> = []

    /// Counts real accessibility writes. Tests check that a disabled service does not increment it.
    private(set) static var mutationCount = 0

    private static let windowNotificationNames: [CFString] = [
        kAXWindowMovedNotification as CFString,
        kAXWindowResizedNotification as CFString,
        kAXWindowMiniaturizedNotification as CFString,
        kAXWindowDeminiaturizedNotification as CFString,
        kAXUIElementDestroyedNotification as CFString,
        kAXTitleChangedNotification as CFString,
    ]

    /// Space fullscreen covers the bar on its own space. Zoomed windows are the ones that should shrink.
    static func shouldLeaveFullScreenAlone(_ isFullScreen: Bool) -> Bool {
        isFullScreen
    }

    func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            TaskbarModel.shared.refreshFromEvent()
        }
    }

    func merge(records: [CGWindowRecord], apps: [pid_t: LiveApp]) -> [WindowInfo] {
        var byID: [CGWindowID: WindowInfo] = [:]
        for record in records {
            let info = record.asWindowInfo()
            if info.isOnScreen, let displayID = info.displayID {
                lastDisplay[info.windowID] = displayID
            }
            byID[info.windowID] = info
        }

        guard Permissions.isAccessibilityTrusted else {
            return byID.values.filter(\.isOnScreen).sorted { $0.windowID < $1.windowID }
        }

        let livePIDs = Set(apps.keys)
        for pid in observers.keys where !livePIDs.contains(pid) {
            stopObserving(pid)
        }

        var freshElements: [CGWindowID: AXUIElement] = [:]
        var freshPIDs: [CGWindowID: pid_t] = [:]
        var failedPIDs = Set<pid_t>()
        for (pid, app) in apps where !app.isHidden {
            ensureObserving(pid)
            let copy = copyWindows(pid: pid)
            if copy.failed {
                failedPIDs.insert(pid)
                for (id, element) in elements where elementPID[id] == pid {
                    freshElements[id] = element
                    freshPIDs[id] = pid
                    let title = AXRead.string(element, kAXTitleAttribute as CFString) ?? ""
                    applyMinimizedState(
                        identifier: id,
                        pid: pid,
                        appName: app.name,
                        title: title,
                        minimized: resolvedMinimized(element, id: id),
                        byID: &byID
                    )
                }
                continue
            }
            let allowSingleCandidate = copy.windows.count == 1
            for element in copy.windows {
                let title = AXRead.string(element, kAXTitleAttribute as CFString) ?? ""
                let privateID = AXPrivate.windowID(for: element)
                let identifier = privateID ?? match(
                    element,
                    pid: pid,
                    title: title,
                    records: records,
                    allowSingleCandidate: allowSingleCandidate
                )
                guard let identifier else { continue }
                if privateID == nil, freshElements[identifier] != nil { continue }
                freshElements[identifier] = element
                freshPIDs[identifier] = pid
                observeWindow(element, id: identifier, pid: pid)
                applyMinimizedState(
                    identifier: identifier,
                    pid: pid,
                    appName: app.name,
                    title: title,
                    minimized: resolvedMinimized(element, id: identifier),
                    byID: &byID
                )
            }
        }
        let liveIDs = Set(byID.keys).union(freshElements.keys)
        for id in Array(observedWindows.keys) where !liveIDs.contains(id) {
            if let pid = observedWindows[id], failedPIDs.contains(pid) { continue }
            unobserve(id)
        }
        for id in lastDisplay.keys where !liveIDs.contains(id) { lastDisplay[id] = nil }
        for id in fittedAt.keys where !liveIDs.contains(id) { fittedAt[id] = nil }
        for id in fitStrikes.keys where !liveIDs.contains(id) { fitStrikes[id] = nil }
        elements = freshElements
        elementPID = freshPIDs

        return byID.values
            .filter { $0.isOnScreen || $0.isMinimized }
            .filter { apps[$0.ownerPID]?.isHidden != true }
            .sorted { $0.windowID < $1.windowID }
    }

    func focusedWindowID(pid: pid_t) -> CGWindowID? {
        guard Permissions.isAccessibilityTrusted else { return nil }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.1)
        guard let focused = AXRead.element(application, kAXFocusedWindowAttribute as CFString) else { return nil }
        if let identifier = AXPrivate.windowID(for: focused) { return identifier }
        let title = AXRead.string(focused, kAXTitleAttribute as CFString) ?? ""
        guard !title.isEmpty else { return nil }
        return elements.first { id, element in
            elementPID[id] == pid && AXRead.string(element, kAXTitleAttribute as CFString) == title
        }?.key
    }

    func focus(windowID: CGWindowID, pid: pid_t) {
        guard Self.systemChangesAllowed else { return }
        pendingMinimized.remove(windowID)
        if let element = elements[windowID] {
            if AXRead.bool(element, kAXMinimizedAttribute as CFString) {
                AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
        activate(pid)
    }

    func minimize(windowID: CGWindowID) {
        guard Self.systemChangesAllowed, let element = elements[windowID] else { return }
        pendingMinimized.insert(windowID)
        AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
    }

    /// AX and CG disagree briefly while a window is miniaturizing. Prefer pending or AX truth.
    private func resolvedMinimized(_ element: AXUIElement, id: CGWindowID) -> Bool {
        let minimized = AXRead.bool(element, kAXMinimizedAttribute as CFString)
        if minimized {
            pendingMinimized.remove(id)
            return true
        }
        return pendingMinimized.contains(id)
    }

    private func applyMinimizedState(
        identifier: CGWindowID,
        pid: pid_t,
        appName: String,
        title: String,
        minimized: Bool,
        byID: inout [CGWindowID: WindowInfo]
    ) {
        if var existing = byID[identifier] {
            if !title.isEmpty { existing.title = title }
            existing.isMinimized = minimized
            if minimized {
                existing.isOnScreen = false
                existing.displayID = lastDisplay[identifier] ?? existing.displayID
            } else if existing.isOnScreen, let displayID = existing.displayID {
                lastDisplay[identifier] = displayID
            }
            byID[identifier] = existing
        } else if minimized {
            let siblings = byID.values.filter { $0.ownerPID == pid }
            let display = lastDisplay[identifier]
                ?? siblings.compactMap(\.displayID).first
                ?? NSScreen.main?.displayID
            byID[identifier] = WindowInfo(
                windowID: identifier,
                ownerPID: pid,
                title: title.isEmpty ? appName : title,
                frame: .zero,
                cgFrame: .zero,
                displayID: display,
                isMinimized: true,
                isOnScreen: false
            )
        }
    }

    func close(windowID: CGWindowID) {
        guard Self.systemChangesAllowed else { return }
        guard let element = elements[windowID],
              let button = AXRead.element(element, kAXCloseButtonAttribute as CFString) else { return }
        AXUIElementPerformAction(button, kAXPressAction as CFString)
    }

    func activate(_ pid: pid_t) {
        guard Self.systemChangesAllowed else { return }
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        if app.isHidden { app.unhide() }
        _ = app.activate(from: .current, options: [])
    }

    func move(windowID: CGWindowID, pid: pid_t, to appKitFrame: CGRect, currentCG: CGRect) {
        guard Self.systemChangesAllowed, ScreenCoordinates.hasPrimaryScreen else { return }
        guard let element = elements[windowID] else { return }
        Self.mutationCount += 1
        if AXRead.bool(element, kAXMinimizedAttribute as CFString) {
            AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        if AXRead.bool(element, "AXFullScreen" as CFString) {
            AXUIElementSetAttributeValue(element, "AXFullScreen" as CFString, kCFBooleanFalse)
        }
        activate(pid)
        setFrame(appKitFrame, element: element, currentCG: currentCG)
        focus(windowID: windowID, pid: pid)
    }

    /// Pulls a zoomed window that fills the screen down to the top of the bar.
    /// A window in its own fullscreen space is left alone.
    func fitMaximized(_ windows: [WindowInfo], occupiedHeight: CGFloat) {
        guard Self.systemChangesAllowed, Permissions.isAccessibilityTrusted, ScreenCoordinates.hasPrimaryScreen else { return }
        let now = Date()
        for window in windows where window.isOnScreen && !window.isMinimized {
            guard let element = elements[window.windowID],
                  let displayID = window.displayID,
                  let screen = ScreenCoordinates.screen(for: displayID),
                  let target = workAreaFrame(for: window.frame, screen: screen, occupiedHeight: occupiedHeight)
            else { continue }
            guard shouldFit(window.windowID, now: now) else { continue }
            if Self.shouldLeaveFullScreenAlone(AXRead.bool(element, "AXFullScreen" as CFString)) { continue }

            setFrame(target, element: element, currentCG: window.cgFrame)
            noteFitAttempt(window.windowID, now: now)
        }
    }

    /// Lifts a maximized window so its bottom sits on the bar. The top edge stays put,
    /// and a window that is already clear of the bar is left alone.
    func workAreaFrame(for window: CGRect, screen: NSScreen, occupiedHeight: CGFloat) -> CGRect? {
        let full = screen.frame
        let top = screen.visibleFrame.maxY
        let barTop = full.minY + occupiedHeight
        let usable = top - full.minY
        guard usable > occupiedHeight + 200 else { return nil }
        let reachesTop = window.maxY >= top - 14
        let bottomNearBar = window.minY <= barTop + 36 && window.minY >= full.minY - 4
        let tall = window.height >= usable * 0.72
        guard reachesTop && bottomNearBar && tall else { return nil }

        let overlap = barTop - window.minY
        guard overlap > 2 else { return nil }
        var next = window
        next.origin.y = barTop
        next.size.height = window.height - overlap
        guard next.height > 200 else { return nil }
        return next
    }

    func shouldFit(_ windowID: CGWindowID, now: Date) -> Bool {
        if let last = fittedAt[windowID], now.timeIntervalSince(last) < 0.45 { return false }
        guard let strikes = fitStrikes[windowID] else { return true }
        if now.timeIntervalSince(strikes.at) > 8 {
            fitStrikes[windowID] = nil
            return true
        }
        return strikes.count < 4
    }

    func noteFitAttempt(_ windowID: CGWindowID, now: Date) {
        fittedAt[windowID] = now
        var strikes = fitStrikes[windowID] ?? (0, now)
        if now.timeIntervalSince(strikes.at) > 8 { strikes = (0, now) }
        strikes.count += 1
        strikes.at = now
        fitStrikes[windowID] = strikes
    }

    func setFrame(_ appKitFrame: CGRect, element: AXUIElement, currentCG: CGRect) {
        guard Self.systemChangesAllowed else { return }
        guard
            let origin = AXRead.point(element, kAXPositionAttribute as CFString),
            let size = AXRead.size(element, kAXSizeAttribute as CFString)
        else { return }
        let current = CGRect(origin: origin, size: size)
        let cgTarget = ScreenCoordinates.cgTopLeft(fromAppKit: appKitFrame)
        let appKitDistance = Self.cornerDistance(current, ScreenCoordinates.appKit(fromCGTopLeft: currentCG))
        let cgDistance = Self.cornerDistance(current, currentCG)
        guard min(appKitDistance, cgDistance) < 160 else { return }
        let desired = cgDistance <= appKitDistance ? cgTarget : appKitFrame
        var point = desired.origin
        var newSize = desired.size
        if let position = AXValueCreate(.cgPoint, &point) {
            AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, position)
        }
        if let sizeValue = AXValueCreate(.cgSize, &newSize) {
            AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
        }
        if let position = AXValueCreate(.cgPoint, &point) {
            AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, position)
        }
    }

    static func cornerDistance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.origin.x - b.origin.x) + abs(a.origin.y - b.origin.y)
            + abs(a.width - b.width) + abs(a.height - b.height)
    }

    struct AXWindowCopy {
        var windows: [AXUIElement]
        /// True when the copy timed out or was skipped. The previous handles for this process stay in use.
        var failed: Bool
    }

    func copyWindows(pid: pid_t) -> AXWindowCopy {
        if let until = backoffUntil[pid], until > Date() {
            return AXWindowCopy(windows: [], failed: true)
        }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.12)
        guard let value = AXRead.copy(application, kAXWindowsAttribute as CFString) else {
            backoffUntil[pid] = Date().addingTimeInterval(2)
            return AXWindowCopy(windows: [], failed: true)
        }
        backoffUntil[pid] = nil
        return AXWindowCopy(windows: value as? [AXUIElement] ?? [], failed: false)
    }

    func match(
        _ element: AXUIElement,
        pid: pid_t,
        title: String,
        records: [CGWindowRecord],
        allowSingleCandidate: Bool = true
    ) -> CGWindowID? {
        let candidates = records.filter { $0.ownerPID == pid }
        if let origin = AXRead.point(element, kAXPositionAttribute as CFString),
           let size = AXRead.size(element, kAXSizeAttribute as CFString) {
            let rect = CGRect(origin: origin, size: size)
            if let hit = candidates.first(where: {
                ScreenCoordinates.roughlyEqual(rect, $0.cgFrame) || ScreenCoordinates.roughlyEqual(rect, $0.appKitFrame)
            }) {
                return hit.windowID
            }
        }
        if !title.isEmpty, let hit = candidates.first(where: { $0.title == title }) {
            return hit.windowID
        }
        if allowSingleCandidate, candidates.count == 1 { return candidates[0].windowID }
        return nil
    }

    func hasElement(for windowID: CGWindowID) -> Bool {
        elements[windowID] != nil
    }

    func remember(_ element: AXUIElement, windowID: CGWindowID, pid: pid_t) {
        elements[windowID] = element
        elementPID[windowID] = pid
    }

    func ensureObserving(_ pid: pid_t) {
        guard Self.systemChangesAllowed else { return }
        guard observers[pid] == nil else { return }
        var observer: AXObserver?
        guard AXObserverCreate(pid, axObserverCallback, &observer) == .success, let observer else { return }
        let application = AXUIElementCreateApplication(pid)
        let names = [
            kAXWindowCreatedNotification,
            kAXFocusedWindowChangedNotification,
            kAXMainWindowChangedNotification,
            kAXApplicationHiddenNotification,
            kAXApplicationShownNotification,
            kAXApplicationActivatedNotification,
        ]
        for name in names {
            AXObserverAddNotification(observer, application, name as CFString, nil)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        observers[pid] = observer
    }

    func observeWindow(_ element: AXUIElement, id: CGWindowID, pid: pid_t) {
        guard Self.systemChangesAllowed else { return }
        guard observedWindows[id] == nil, let observer = observers[pid] else { return }
        for name in Self.windowNotificationNames {
            AXObserverAddNotification(observer, element, name, nil)
        }
        observedWindows[id] = pid
    }

    func forgetDestroyed(_ element: AXUIElement) {
        let ids = elements.compactMap { id, stored in CFEqual(stored, element) ? id : nil }
        for id in ids {
            unobserve(id)
        }
    }

    func unobserve(_ id: CGWindowID) {
        let pid = observedWindows.removeValue(forKey: id)
        if let pid, let observer = observers[pid], let element = elements[id] {
            for name in Self.windowNotificationNames {
                AXObserverRemoveNotification(observer, element, name)
            }
        }
        elements[id] = nil
        elementPID[id] = nil
        lastDisplay[id] = nil
        fittedAt[id] = nil
        fitStrikes[id] = nil
        pendingMinimized.remove(id)
    }

    func stopObserving(_ pid: pid_t) {
        let ids = observedWindows.compactMap { id, owner in owner == pid ? id : nil }
        for id in ids { unobserve(id) }
        guard let observer = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }
}

enum AXRead {
    static func copy(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute, &value)
        return status == .success ? value : nil
    }

    static func string(_ element: AXUIElement, _ attribute: CFString) -> String? {
        copy(element, attribute) as? String
    }

    static func bool(_ element: AXUIElement, _ attribute: CFString) -> Bool {
        (copy(element, attribute) as? NSNumber)?.boolValue ?? false
    }

    static func element(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        guard let value = copy(element, attribute) else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    static func point(_ element: AXUIElement, _ attribute: CFString) -> CGPoint? {
        guard let value = axValue(copy(element, attribute)) else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &point) ? point : nil
    }

    static func size(_ element: AXUIElement, _ attribute: CFString) -> CGSize? {
        guard let value = axValue(copy(element, attribute)) else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value, .cgSize, &size) ? size : nil
    }

    private static func axValue(_ value: CFTypeRef?) -> AXValue? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXValue.self)
    }
}
