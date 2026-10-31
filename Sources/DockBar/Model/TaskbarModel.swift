import AppKit
import CoreGraphics
import Foundation
import Observation

@MainActor
@Observable
final class TaskbarModel {
    static let shared = TaskbarModel()
    static let finderBundleID = "com.apple.finder"

    let settings: BarSettings
    private(set) var entriesByScreen: [CGDirectDisplayID: [AppItem]] = [:]
    private(set) var trashCount = 0

    @ObservationIgnored private var pins: [Pin] = []
    @ObservationIgnored private var liveApps: [pid_t: LiveApp] = [:]
    @ObservationIgnored private var windows: [WindowInfo] = []
    @ObservationIgnored private var focusedPID: pid_t?
    @ObservationIgnored private var focusedWindowID: CGWindowID?
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var fitTask: Task<Void, Never>?
    @ObservationIgnored private var steerTask: Task<Void, Never>?

    var dragID: String?
    var dragDisplay: CGDirectDisplayID?
    private(set) var dragDX: CGFloat = 0

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.settings = BarSettings(defaults: defaults)
    }

    func start() {
        settings.onChange = { [weak self] in
            guard let self else { return }
            if !self.settings.openWindowsOnClickedDisplay {
                self.steerTask?.cancel()
            }
            self.recompute()
            self.scheduleFit()
        }
        loadPins()
        refresh(clearance: false)
        TrashService.shared.start()
        Log.info("DockBar started with \(self.pins.count) pins")
    }

    func refreshFromEvent() {
        refresh(clearance: false)
        scheduleFit()
    }

    func refresh(clearance: Bool) {
        refreshApps()
        let records = WindowTracker.snapshot(allowedPIDs: Set(liveApps.keys))
        windows = BrowserProfile.stamp(AXWindowService.shared.merge(records: records, apps: liveApps), apps: liveApps)
        focusedPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if let focusedPID, Permissions.isAccessibilityTrusted {
            if let identifier = AXWindowService.shared.focusedWindowID(pid: focusedPID) {
                focusedWindowID = identifier
            }
        } else {
            focusedWindowID = nil
        }
        ThumbnailService.shared.discardMissing(keeping: Set(windows.map(\.windowID)))
        recompute()
        if clearance {
            AXWindowService.shared.fitMaximized(windows, occupiedHeight: settings.occupiedHeight)
        }
    }

    func noteTrashCount(_ count: Int) {
        trashCount = count
    }

    func entries(for displayID: CGDirectDisplayID) -> [AppItem] {
        entriesByScreen[displayID] ?? []
    }

    func panelFrame(for screen: NSScreen) -> CGRect {
        let height = settings.barHeight
        switch settings.style {
        case .fullWidth:
            return CGRect(x: screen.frame.minX, y: screen.frame.minY, width: screen.frame.width, height: height)
        case .floating:
            let row = entries(for: screen.displayID)
            let showsFinderDivider = row.contains { $0.isPinned && settings.showFinder && $0.bundleID == Self.finderBundleID }
            let width = min(
                screen.frame.width - 24,
                BarLayout.floatingWidth(itemCount: row.count, settings: settings, showsFinderDivider: showsFinderDivider)
            )
            return CGRect(
                x: screen.frame.midX - width / 2,
                y: screen.frame.minY + settings.bottomGap,
                width: width,
                height: height
            )
        }
    }

    func dragOffset(for item: AppItem, displayID: CGDirectDisplayID) -> CGFloat {
        guard let dragID, dragDisplay == displayID, abs(dragDX) > 1 else { return 0 }
        let row = entries(for: displayID)
        guard let origin = row.firstIndex(where: { $0.id == dragID }),
              let index = row.firstIndex(where: { $0.id == item.id }),
              row[origin].isPinned else { return 0 }
        let stride = settings.iconStride
        let minSlot = finderLocked(in: row) ? 1 : 0
        if origin < minSlot { return 0 }
        if item.id == dragID { return dragDX }
        guard item.isPinned else { return 0 }
        let pinnedLast = row.lastIndex(where: \.isPinned) ?? origin
        let steps = Int((dragDX / stride).rounded())
        let destination = min(max(origin + steps, minSlot), pinnedLast)
        if steps > 0, index > origin, index <= destination { return -stride }
        if steps < 0, index < origin, index >= destination { return stride }
        return 0
    }

    func beginDrag(id: String, displayID: CGDirectDisplayID) {
        if settings.showFinder && id == Self.finderBundleID { return }
        dragID = id
        dragDisplay = displayID
        dragDX = 0
        PreviewCoordinator.shared.hide()
    }

    func updateDrag(dx: CGFloat, mouse: CGPoint = NSEvent.mouseLocation) {
        dragDX = dx
        let over = mouseIsOverTrash(mouse)
        if over != trashDragHover { trashDragHover = over }
    }

    var trashDragHover = false

    private func mouseIsOverTrash(_ mouse: CGPoint) -> Bool {
        guard settings.showTrash, settings.trashSlot > 0 else { return false }
        return NSScreen.screens.contains { screen in
            let frame = panelFrame(for: screen)
            let trash = CGRect(x: frame.maxX - settings.trashSlot, y: frame.minY, width: settings.trashSlot, height: frame.height)
            return trash.contains(mouse)
        }
    }

    private func removeFavorite(id: String) {
        if id == Self.finderBundleID {
            settings.showFinder = false
        }
        pins.removeAll { $0.id == id }
        savePins()
    }

    func endDrag(at mouse: CGPoint = NSEvent.mouseLocation) {
        guard let dragID, let dragDisplay else {
            clearDrag()
            return
        }
        let overTrash = NSScreen.screens.contains { screen in
            let frame = panelFrame(for: screen)
            let slot = settings.trashSlot
            let trash = CGRect(x: frame.maxX - slot, y: frame.minY, width: slot, height: frame.height)
            return settings.showTrash && trash.contains(mouse)
        }
        if overTrash {
            removeFavorite(id: dragID)
            clearDrag()
            recompute()
            return
        }
        let row = entries(for: dragDisplay).filter(\.isPinned)
        if let origin = row.firstIndex(where: { $0.id == dragID }) {
            let steps = Int((dragDX / settings.iconStride).rounded())
            let minSlot = finderLocked(in: row) ? 1 : 0
            guard origin >= minSlot else {
                clearDrag()
                recompute()
                return
            }
            let destination = min(max(origin + steps, minSlot), row.count - 1)
            if origin != destination {
                var ids = row.map(\.id)
                let moved = ids.remove(at: origin)
                ids.insert(moved, at: destination)
                var ordered: [Pin] = []
                for id in ids {
                    if let pin = pins.first(where: { $0.id == id }) {
                        ordered.append(pin)
                    }
                }
                for pin in pins where !ids.contains(pin.id) {
                    ordered.append(pin)
                }
                pins = ordered
                savePins()
            }
        }
        clearDrag()
        recompute()
    }

    func primaryClick(_ item: AppItem, displayID: CGDirectDisplayID, anchor: CGRect) {
        guard item.isRunning, let pid = item.pid else {
            if isFinder(item) {
                openFinderWindow(on: displayID)
            } else {
                launch(item, on: displayID)
            }
            PreviewCoordinator.shared.hide()
            return
        }
        let windows = item.windowsOnScreen
        if windows.isEmpty {
            if isFinder(item) {
                openFinderWindow(on: displayID)
            } else {
                let previous = Set(self.windows.filter { $0.ownerPID == pid }.map(\.windowID))
                AXWindowService.shared.activate(pid)
                steerApp(pid: pid, onto: displayID, previous: previous, moveExisting: true)
            }
            PreviewCoordinator.shared.hide()
            return
        }
        if windows.count == 1, let window = windows.first {
            if window.isMinimized || focusedWindowID != window.windowID {
                AXWindowService.shared.focus(windowID: window.windowID, pid: window.ownerPID)
                focusedWindowID = window.windowID
            } else {
                AXWindowService.shared.minimize(windowID: window.windowID)
            }
            PreviewCoordinator.shared.hide()
            recompute()
            return
        }
        if PreviewCoordinator.shared.isShowing(item.id) {
            cycle(item)
            PreviewCoordinator.shared.hide()
        } else {
            PreviewCoordinator.shared.show(appID: item.id, anchor: anchor, displayID: displayID)
        }
    }

    func newWindow(for item: AppItem, on displayID: CGDirectDisplayID) {
        if isFinder(item) {
            openFinderWindow(on: displayID)
            return
        }
        guard item.isRunning, let pid = item.pid else {
            launch(item, on: displayID)
            return
        }
        let previous = Set(windows.filter { $0.ownerPID == pid }.map(\.windowID))
        AXWindowService.shared.activate(pid)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            Self.postCommandN(to: pid)
        }
        steerApp(pid: pid, onto: displayID, previous: previous, moveExisting: false)
    }

    func isWindowFocused(_ window: WindowInfo) -> Bool {
        window.windowID == focusedWindowID
    }

    func focus(_ window: WindowInfo) {
        AXWindowService.shared.focus(windowID: window.windowID, pid: window.ownerPID)
        focusedWindowID = window.windowID
        PreviewCoordinator.shared.hide()
        recompute()
    }

    func close(_ window: WindowInfo) {
        AXWindowService.shared.close(windowID: window.windowID)
        scheduleFollowUpRefresh()
    }

    func pin(_ item: AppItem) {
        guard !pins.contains(where: { $0.id == item.id }) else { return }
        pins.append(Pin(path: item.path, bundleID: item.bundleID, name: item.name))
        savePins()
        recompute()
    }

    func unpin(_ item: AppItem) {
        pins.removeAll { $0.id == item.id }
        savePins()
        recompute()
    }

    func togglePin(_ item: AppItem) {
        if item.isPinned {
            if settings.showFinder && isFinder(item) {
                settings.showFinder = false
                pins.removeAll { isFinder($0) }
                savePins()
                recompute()
                return
            }
            unpin(item)
        } else {
            pin(item)
        }
    }

    func reveal(_ item: AppItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.bundleURL])
    }

    func quit(_ item: AppItem) {
        guard let pid = item.pid else { return }
        NSRunningApplication(processIdentifier: pid)?.terminate()
    }

    func launch(_ item: AppItem, on displayID: CGDirectDisplayID) {
        let url = item.bundleURL
        let previous = Set(windows.filter { $0.ownerPID == item.pid }.map(\.windowID))
        guard url.pathExtension == "app" else {
            NSWorkspace.shared.open(url)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
            if let error {
                Log.error("Could not open \(url.path): \(error.localizedDescription)")
            }
            let pid = app?.processIdentifier
            Task { @MainActor in
                guard let pid else { return }
                TaskbarModel.shared.steerApp(pid: pid, onto: displayID, previous: previous, moveExisting: true)
            }
        }
    }

    private func cycle(_ item: AppItem) {
        let windows = item.windowsOnScreen
        guard !windows.isEmpty else { return }
        let current = windows.firstIndex { $0.windowID == focusedWindowID } ?? -1
        let next = windows[(current + 1) % windows.count]
        focus(next)
    }

    private func scheduleFit() {
        fitTask?.cancel()
        fitTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled else { return }
            self.refresh(clearance: true)
        }
    }

    private func scheduleFollowUpRefresh() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            self.refresh(clearance: false)
        }
    }

    private nonisolated static func postCommandN(to pid: pid_t) {
        let source = CGEventSource(stateID: .hidSystemState)
        let key: CGKeyCode = 0x2D
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(pid)
        up.postToPid(pid)
    }

    private func refreshApps() {
        var next: [pid_t: LiveApp] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let url = app.bundleURL else { continue }
            let path = url.resolvingSymlinksInPath().path
            next[app.processIdentifier] = LiveApp(
                pid: app.processIdentifier,
                bundleID: app.bundleIdentifier,
                path: path,
                name: app.localizedName ?? url.deletingPathExtension().lastPathComponent,
                isHidden: app.isHidden
            )
        }
        liveApps = next
    }

    func loadSnapshot(
        pins: [Pin] = [],
        apps: [pid_t: LiveApp] = [:],
        windows: [WindowInfo] = [],
        focusedPID: pid_t? = nil,
        focusedWindowID: CGWindowID? = nil
    ) {
        self.pins = pins
        self.liveApps = apps
        self.windows = windows
        self.focusedPID = focusedPID
        self.focusedWindowID = focusedWindowID
        recompute()
    }

    private func recompute() {
        var map: [CGDirectDisplayID: [AppItem]] = [:]
        for screen in NSScreen.screens {
            map[screen.displayID] = makeEntries(for: screen.displayID)
        }
        entriesByScreen = map
        onChange?()
    }

    private func makeEntries(for displayID: CGDirectDisplayID) -> [AppItem] {
        var items: [AppItem] = []
        var shown = Set<String>()

        let primaryID = NSScreen.screens.first { $0.frame.origin == .zero }?.displayID
        let includePins = settings.showPinnedOnAllScreens || displayID == primaryID
        if includePins {
            var source = pins
            if settings.showFinder, let finder = finderPin() {
                source.removeAll { isFinder($0) }
                source.insert(finder, at: 0)
            }
            for pin in source {
                guard let path = resolvedPath(for: pin) else { continue }
                let identity = pin.id
                let matches = liveApps.values.filter { $0.id == identity || $0.path == path }
                let pids = Set(matches.map(\.pid))
                let wins = windowsOn(displayID, pids: pids)
                let pid = wins.first?.ownerPID ?? matches.first?.pid
                let name = matches.first?.name ?? pin.name
                items.append(AppItem(
                    id: identity,
                    name: name,
                    path: path,
                    bundleID: pin.bundleID ?? matches.first?.bundleID,
                    pid: pid,
                    isPinned: true,
                    isRunning: !matches.isEmpty,
                    windowsOnScreen: wins,
                    isActive: isActive(pid: pid, windows: wins)
                ))
                shown.insert(identity)
            }
        }

        let visible = windows.filter { $0.displayID == displayID && isListedWindow($0) }
        let grouped = Dictionary(grouping: visible, by: \.ownerPID)
        for (pid, wins) in grouped.sorted(by: { $0.key < $1.key }) {
            guard let app = liveApps[pid] else { continue }
            if shown.contains(app.id) {
                if let index = items.firstIndex(where: { $0.id == app.id }) {
                    var merged = items[index].windowsOnScreen
                    for window in wins where !merged.contains(where: { $0.windowID == window.windowID }) {
                        merged.append(window)
                    }
                    items[index].windowsOnScreen = merged
                    items[index].pid = wins.first?.ownerPID ?? items[index].pid
                    items[index].isActive = isActive(pid: items[index].pid, windows: merged)
                }
                continue
            }
            items.append(AppItem(
                id: app.id,
                name: app.name,
                path: app.path,
                bundleID: app.bundleID,
                pid: pid,
                isPinned: false,
                isRunning: true,
                windowsOnScreen: wins,
                isActive: isActive(pid: pid, windows: wins)
            ))
            shown.insert(app.id)
        }
        return items
    }

    private func windowsOn(_ displayID: CGDirectDisplayID, pids: Set<pid_t>) -> [WindowInfo] {
        windows.filter { pids.contains($0.ownerPID) && $0.displayID == displayID && isListedWindow($0) }
    }

    /// Finder keeps short offscreen strips (menu bar, desktop) that are not folder windows.
    private func isListedWindow(_ window: WindowInfo) -> Bool {
        guard window.isOnScreen || window.isMinimized else { return false }
        if liveApps[window.ownerPID]?.bundleID == Self.finderBundleID,
           window.frame.height > 0, window.frame.height < 80 {
            return false
        }
        return true
    }

    private func openFinderWindow(on displayID: CGDirectDisplayID) {
        let pid = NSRunningApplication.runningApplications(withBundleIdentifier: Self.finderBundleID).first?.processIdentifier
        let previous = Set(windows.filter { $0.ownerPID == pid }.map(\.windowID))
        NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser)
        if let pid {
            steerApp(pid: pid, onto: displayID, previous: previous, moveExisting: true)
        }
    }

    /// Watches for the app's window and moves it onto the screen that was clicked.
    private func steerApp(pid: pid_t, onto displayID: CGDirectDisplayID, previous: Set<CGWindowID>, moveExisting: Bool) {
        steerTask?.cancel()
        guard settings.openWindowsOnClickedDisplay else { return }
        steerTask = Task { @MainActor in
            let pauses: [Duration] = [
                .milliseconds(200), .milliseconds(300), .milliseconds(400),
                .milliseconds(500), .milliseconds(800), .milliseconds(1000),
            ]
            for pause in pauses {
                try? await Task.sleep(for: pause)
                guard !Task.isCancelled, self.settings.openWindowsOnClickedDisplay else { return }
                self.refresh(clearance: false)
                if self.placeWindow(pid: pid, on: displayID, previous: previous, moveExisting: moveExisting) {
                    return
                }
            }
        }
    }

    /// Returns true once a window is on the target screen and focused.
    func placeWindow(pid: pid_t, on displayID: CGDirectDisplayID, previous: Set<CGWindowID>, moveExisting: Bool) -> Bool {
        let mine = windows.filter { window in
            window.ownerPID == pid && isListedWindow(window) && (window.frame.height == 0 || window.frame.height >= 80)
        }
        if let window = mine.first(where: { !previous.contains($0.windowID) }) {
            if window.displayID == displayID && window.isOnScreen && !window.isMinimized && window.frame.height >= 80 {
                AXWindowService.shared.focus(windowID: window.windowID, pid: pid)
                focusedWindowID = window.windowID
                return true
            }
            relocate(window, to: displayID)
            return false
        }
        guard moveExisting else { return false }
        if let here = mine.first(where: { $0.displayID == displayID && $0.isOnScreen && !$0.isMinimized && $0.frame.height >= 80 }) {
            AXWindowService.shared.focus(windowID: here.windowID, pid: pid)
            focusedWindowID = here.windowID
            return true
        }
        guard let window = mine.first(where: { $0.windowID == focusedWindowID }) ?? mine.first else { return false }
        relocate(window, to: displayID)
        return false
    }

    private func relocate(_ window: WindowInfo, to displayID: CGDirectDisplayID) {
        guard let target = ScreenCoordinates.screen(for: displayID) else { return }
        guard window.frame.width >= 80, window.frame.height >= 80 else {
            AXWindowService.shared.focus(windowID: window.windowID, pid: window.ownerPID)
            return
        }
        let source = window.displayID.flatMap { ScreenCoordinates.screen(for: $0) }
        let frame = frame(window.frame, from: source, to: target)
        AXWindowService.shared.move(windowID: window.windowID, pid: window.ownerPID, to: frame, currentCG: window.cgFrame)
    }

    func frame(_ window: CGRect, from source: NSScreen?, to target: NSScreen) -> CGRect {
        let occupied = settings.occupiedHeight
        let targetWork = workArea(of: target, occupiedHeight: occupied)
        guard let source else {
            var centered = window
            centered.origin.x = targetWork.midX - window.width / 2
            centered.origin.y = targetWork.midY - window.height / 2
            return clamped(centered, to: targetWork)
        }
        let sourceWork = workArea(of: source, occupiedHeight: occupied)
        let fills = window.width >= source.frame.width * 0.8 && window.height >= sourceWork.height * 0.75
        if fills { return targetWork }
        let relX = sourceWork.width > 1 ? (window.minX - sourceWork.minX) / sourceWork.width : 0
        let relY = sourceWork.height > 1 ? (window.minY - sourceWork.minY) / sourceWork.height : 0
        var next = window
        next.size.width = min(window.width, targetWork.width)
        next.size.height = min(window.height, targetWork.height)
        next.origin.x = targetWork.minX + relX * max(targetWork.width - next.width, 0)
        next.origin.y = targetWork.minY + relY * max(targetWork.height - next.height, 0)
        return clamped(next, to: targetWork)
    }

    func workArea(of screen: NSScreen, occupiedHeight: CGFloat) -> CGRect {
        let bottom = screen.frame.minY + occupiedHeight
        let height = max(screen.visibleFrame.maxY - bottom, 200)
        return CGRect(x: screen.frame.minX, y: bottom, width: screen.frame.width, height: height)
    }

    func clamped(_ rect: CGRect, to work: CGRect) -> CGRect {
        var next = rect
        next.size.width = min(max(next.width, 80), work.width)
        next.size.height = min(max(next.height, 80), work.height)
        next.origin.x = min(max(next.origin.x, work.minX), work.maxX - next.width)
        next.origin.y = min(max(next.origin.y, work.minY), work.maxY - next.height)
        return next
    }

    private func isActive(pid: pid_t?, windows: [WindowInfo]) -> Bool {
        guard !windows.isEmpty else { return false }
        if let focusedWindowID, windows.contains(where: { $0.windowID == focusedWindowID }) {
            return true
        }
        if focusedWindowID == nil, let pid, pid == focusedPID {
            return true
        }
        return false
    }

    private func finderLocked(in row: [AppItem]) -> Bool {
        settings.showFinder && row.first?.bundleID == Self.finderBundleID
    }

    private func isFinder(_ pin: Pin) -> Bool {
        pin.bundleID == Self.finderBundleID || pin.id == Self.finderBundleID
    }

    private func isFinder(_ item: AppItem) -> Bool {
        item.bundleID == Self.finderBundleID || item.id == Self.finderBundleID
    }

    private func finderPin() -> Pin? {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.finderBundleID)
            ?? URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        let path = url.resolvingSymlinksInPath().path
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return Pin(path: path, bundleID: Self.finderBundleID, name: "Finder")
    }

    private func resolvedPath(for pin: Pin) -> String? {
        if FileManager.default.fileExists(atPath: pin.path) {
            return URL(fileURLWithPath: pin.path).resolvingSymlinksInPath().path
        }
        if let bundleID = pin.bundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url.resolvingSymlinksInPath().path
        }
        return nil
    }

    private func loadPins() {
        if let data = defaults.data(forKey: "pins"),
           let stored = try? JSONDecoder().decode([Pin].self, from: data) {
            pins = stored
            return
        }
        pins = DockPinsReader.read()
        savePins()
    }

    private func savePins() {
        if let data = try? JSONEncoder().encode(pins) {
            defaults.set(data, forKey: "pins")
        }
    }

    private func clearDrag() {
        dragID = nil
        dragDisplay = nil
        dragDX = 0
        trashDragHover = false
    }
}
