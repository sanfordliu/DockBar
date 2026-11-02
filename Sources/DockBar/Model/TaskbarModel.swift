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
    /// One icon at a time. Adjacent tracking areas otherwise both look hovered.
    var hoveredAppID: String?
    /// Where an app dragged in from Finder will be inserted, among pinned icons.
    var dropDisplay: CGDirectDisplayID?
    var dropVisualIndex: Int?
    /// Set when a click asks to move a window that already exists. Tests read this.
    private(set) var relocatedWindowID: CGWindowID?

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
            focusedWindowID = AXWindowService.shared.focusedWindowID(pid: focusedPID)
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
            let base = min(
                screen.frame.width - 24,
                BarLayout.floatingWidth(items: row, settings: settings, showsFinderDivider: showsFinderDivider)
            )
            let gap = barTrailingGap(for: screen.displayID)
            let width = min(screen.frame.width - 24, base + gap)
            let originX = screen.frame.midX - width / 2
            let minX = screen.frame.minX
            let maxX = max(minX, screen.frame.maxX - width)
            return CGRect(
                x: min(max(originX, minX), maxX),
                y: screen.frame.minY + settings.bottomGap,
                width: width,
                height: height
            )
        }
    }

    func dragOffset(for item: AppItem, displayID: CGDirectDisplayID) -> CGFloat {
        guard let dragID, dragDisplay == displayID, abs(dragDX) > 1 else { return 0 }
        let row = entries(for: displayID)
        let runs = iconRuns(in: row)
        guard let origin = runs.firstIndex(where: { row[$0.anchorIndex].id == dragID }),
              let index = row.firstIndex(where: { $0.id == item.id }) else { return 0 }
        let originRun = runs[origin]
        let minSlot = finderLocked(in: row) ? 1 : 0
        if origin < minSlot { return 0 }
        let minDX = -runWidth(runs, from: minSlot, to: origin)
        let inDragged = index >= originRun.anchorIndex && index < originRun.anchorIndex + originRun.length
        if inDragged { return max(dragDX, minDX) }
        guard let runIndex = runs.firstIndex(where: { index >= $0.anchorIndex && index < $0.anchorIndex + $0.length }) else {
            return 0
        }
        if trashDragHover { return runIndex > origin ? -originRun.width : 0 }
        let dx = min(max(dragDX, minDX), runWidth(runs, from: origin + 1, to: runs.count))
        let destination = pinSlot(runs: runs, origin: origin, dragDX: dx, minSlot: minSlot)
        if destination > origin, runIndex > origin, runIndex <= destination { return -originRun.width }
        if destination < origin, runIndex < origin, runIndex >= destination { return originRun.width }
        return 0
    }

    /// Extra width so an external drop can open a gap. Reordering stays inside the bar.
    func barTrailingGap(for displayID: CGDirectDisplayID) -> CGFloat {
        guard dragID == nil, dropDisplay == displayID, dropVisualIndex != nil else { return 0 }
        return settings.iconStride
    }

    func setHoveredApp(_ id: String) {
        guard dragID == nil else { return }
        hoveredAppID = id
    }

    func clearHoveredApp(_ id: String) {
        guard hoveredAppID == id else { return }
        hoveredAppID = nil
    }

    func beginDrag(id: String, displayID: CGDirectDisplayID) {
        if settings.showFinder && id == Self.finderBundleID { return }
        dragID = id
        dragDisplay = displayID
        dragDX = 0
        hoveredAppID = nil
        clearDropTarget()
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
        let row = entries(for: dragDisplay)
        let runs = iconRuns(in: row)
        if let origin = runs.firstIndex(where: { row[$0.anchorIndex].id == dragID }) {
            let minSlot = finderLocked(in: row) ? 1 : 0
            guard origin >= minSlot else {
                clearDrag()
                recompute()
                return
            }
            let destination = pinSlot(runs: runs, origin: origin, dragDX: dragDX, minSlot: minSlot)
            if origin != destination {
                var ids = runs.map { row[$0.anchorIndex].pinID }
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
        guard !pins.contains(where: { $0.id == item.pinID }) else { return }
        pins.append(Pin(path: item.path, bundleID: item.bundleID, name: item.name))
        savePins()
        recompute()
    }

    /// Inserts dropped apps at the cursor. Without a point, they go on the end.
    func pinApplications(_ urls: [URL], at screenPoint: CGPoint? = nil) {
        var visual = screenPoint.flatMap { visualPinInsertIndex(at: $0) }
        var changed = false
        for url in urls {
            guard let pin = Self.pin(forApplication: url) else { continue }
            if pin.bundleID == Self.finderBundleID || isFinder(pin) {
                if !settings.showFinder {
                    settings.showFinder = true
                    changed = true
                }
                continue
            }
            guard !pins.contains(where: { $0.id == pin.id }) else { continue }
            insertPin(pin, atVisual: visual)
            changed = true
            if let step = visual { visual = step + 1 }
        }
        guard changed else { return }
        savePins()
        recompute()
    }

    /// Pinned-icon index under a screen point. Finder stays first.
    func visualPinInsertIndex(at point: CGPoint) -> Int? {
        guard let screen = NSScreen.screens.first(where: { panelFrame(for: $0).contains(point) }) else { return nil }
        let row = entries(for: screen.displayID)
        let runs = iconRuns(in: row)
        let start = iconClusterMinX(on: screen, row: row)
        var x = start
        let earliest = finderLocked(in: row) ? 1 : 0
        let gapIndex = dropDisplay == screen.displayID ? dropVisualIndex : nil
        for (index, run) in runs.enumerated() {
            if gapIndex == index { x += settings.iconStride }
            if point.x < x + run.width / 2 { return max(index, earliest) }
            x += run.width
            if run.showsDivider { x += BarLayout.dividerWidth }
        }
        return max(runs.count, earliest)
    }

    func trackDrop(at screenPoint: CGPoint) {
        guard let screen = NSScreen.screens.first(where: { panelFrame(for: $0).contains(screenPoint) }),
              let visual = visualPinInsertIndex(at: screenPoint) else {
            clearDropTarget()
            return
        }
        let display = screen.displayID
        guard dropDisplay != display || dropVisualIndex != visual else { return }
        dropDisplay = display
        dropVisualIndex = visual
        onChange?()
    }

    func clearDropTarget() {
        guard dropDisplay != nil || dropVisualIndex != nil else { return }
        dropDisplay = nil
        dropVisualIndex = nil
        onChange?()
    }

    /// Slides icons apart so a dropped app can land under the pointer.
    func dropGapOffset(for item: AppItem, displayID: CGDirectDisplayID) -> CGFloat {
        guard dragID == nil, dropDisplay == displayID, let visual = dropVisualIndex else { return 0 }
        let row = entries(for: displayID)
        guard let index = row.firstIndex(where: { $0.id == item.id }) else { return 0 }
        let runs = iconRuns(in: row)
        let gapRowIndex: Int
        if visual >= runs.count {
            gapRowIndex = runs.last.map { $0.anchorIndex + $0.length } ?? 0
        } else {
            gapRowIndex = runs[visual].anchorIndex
        }
        return index >= gapRowIndex ? settings.iconStride : 0
    }

    private func insertPin(_ pin: Pin, atVisual visual: Int?) {
        var ordered = pins.filter { !isFinder($0) }
        if settings.showFinder, let finder = finderPin() {
            ordered.insert(finder, at: 0)
        }
        let earliest = (settings.showFinder && ordered.first.map { isFinder($0) } == true) ? 1 : 0
        let index = min(max(visual ?? ordered.count, earliest), ordered.count)
        ordered.insert(pin, at: index)
        if settings.showFinder {
            ordered.removeAll { isFinder($0) }
        }
        pins = ordered
    }

    /// One pinned app plus the extra window buttons that sit in its slot.
    struct IconRun {
        var anchorIndex: Int
        var length: Int
        var width: CGFloat
        var showsDivider: Bool
    }

    func iconRuns(in row: [AppItem]) -> [IconRun] {
        var runs: [IconRun] = []
        var index = 0
        while index < row.count {
            guard row[index].isPinned else { break }
            let pinID = row[index].pinID
            var length = 1
            var next = index + 1
            while next < row.count, !row[next].isPinned, row[next].pinID == pinID {
                length += 1
                next += 1
            }
            let finder = row[index].bundleID == Self.finderBundleID || pinID == Self.finderBundleID
            let width = (0..<length).reduce(CGFloat(0)) { total, offset in
                total + settings.buttonWidth(for: row[index + offset])
            }
            runs.append(IconRun(
                anchorIndex: index,
                length: length,
                width: width,
                showsDivider: settings.showFinder && finder
            ))
            index = next
        }
        return runs
    }

    func showsDivider(after item: AppItem, in row: [AppItem]) -> Bool {
        guard let index = row.firstIndex(where: { $0.id == item.id }) else { return false }
        return iconRuns(in: row).contains { run in
            run.showsDivider && index == run.anchorIndex + run.length - 1
        }
    }

    private func runWidth(_ runs: [IconRun], from start: Int, to end: Int) -> CGFloat {
        guard start < end, start >= 0, end <= runs.count else { return 0 }
        return runs[start..<end].reduce(0) { $0 + $1.width }
    }

    /// Pin slot the pointer has crossed. One-icon runs match rounding `dragDX / stride`.
    private func pinSlot(runs: [IconRun], origin: Int, dragDX: CGFloat, minSlot: Int) -> Int {
        guard !runs.isEmpty else { return origin }
        var destination = origin
        var remaining = dragDX
        if dragDX > 0 {
            while destination < runs.count - 1 {
                let next = runs[destination + 1].width
                if remaining < next / 2 { break }
                remaining -= next
                destination += 1
            }
        } else if dragDX < 0 {
            while destination > minSlot {
                let previous = runs[destination - 1].width
                if -remaining < previous / 2 { break }
                remaining += previous
                destination -= 1
            }
        }
        return destination
    }

    /// Left edge of the first icon, matching the bar's SwiftUI layout.
    private func iconClusterMinX(on screen: NSScreen, row: [AppItem]) -> CGFloat {
        let panel = panelFrame(for: screen)
        var cluster: CGFloat = 0
        for item in row {
            cluster += settings.buttonWidth(for: item)
            if showsDivider(after: item, in: row) { cluster += BarLayout.dividerWidth }
        }
        if settings.style == .floating {
            return panel.minX + BarLayout.edgeInset
        }
        let leadingPad: CGFloat = settings.alignment == .leading ? 8 : 0
        let leftBalance: CGFloat = (settings.alignment == .center && settings.showTrash) ? settings.trashSlot : 0
        let trashCluster: CGFloat = settings.showTrash
            ? BarLayout.dividerWidth + settings.effectiveIconSize + BarLayout.trashInset * 2 + 10
            : 10
        let used = leadingPad + leftBalance + cluster + trashCluster
        let extra = max(0, panel.width - used)
        let leftSpacer: CGFloat = settings.alignment == .center ? extra / 2 : 0
        return panel.minX + leadingPad + leftBalance + leftSpacer
    }

    static func pin(forApplication url: URL) -> Pin? {
        let resolved = url.resolvingSymlinksInPath()
        guard resolved.pathExtension.lowercased() == "app" else { return nil }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &directory), directory.boolValue else {
            return nil
        }
        let bundle = Bundle(url: resolved)
        let bundleID = bundle?.bundleIdentifier
        let name = bundle?.localizedInfoDictionary?["CFBundleDisplayName"] as? String
            ?? bundle?.infoDictionary?["CFBundleDisplayName"] as? String
            ?? bundle?.infoDictionary?["CFBundleName"] as? String
            ?? FileManager.default.displayName(atPath: resolved.path)
        return Pin(path: resolved.path, bundleID: bundleID, name: name)
    }

    func unpin(_ item: AppItem) {
        pins.removeAll { $0.id == item.pinID }
        savePins()
        recompute()
    }

    func togglePin(_ item: AppItem) {
        if item.appIsPinned {
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
                Log.error("Could not open application: \(error.localizedDescription)", path: url.path)
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
                let bundleID = pin.bundleID ?? matches.first?.bundleID
                if settings.groupWindows || wins.count <= 1 {
                    items.append(appButton(
                        id: identity,
                        appID: identity,
                        name: name,
                        path: path,
                        bundleID: bundleID,
                        pid: pid,
                        isPinned: true,
                        followsPin: true,
                        isRunning: !matches.isEmpty,
                        windows: wins,
                        focus: nil
                    ))
                } else {
                    for (offset, window) in wins.enumerated() {
                        items.append(appButton(
                            id: offset == 0 ? identity : "\(identity)#\(window.windowID)",
                            appID: identity,
                            name: name,
                            path: path,
                            bundleID: bundleID,
                            pid: window.ownerPID,
                            isPinned: offset == 0,
                            followsPin: true,
                            isRunning: true,
                            windows: [window],
                            focus: window
                        ))
                    }
                }
                shown.insert(identity)
            }
        }

        let visible = windows.filter { $0.displayID == displayID && isListedWindow($0) }
        let grouped = Dictionary(grouping: visible, by: \.ownerPID)
        for (pid, wins) in grouped.sorted(by: { $0.key < $1.key }) {
            guard let app = liveApps[pid] else { continue }
            if shown.contains(app.id) {
                if settings.groupWindows {
                    if let index = items.firstIndex(where: { $0.id == app.id }) {
                        var merged = items[index].windowsOnScreen
                        for window in wins where !merged.contains(where: { $0.windowID == window.windowID }) {
                            merged.append(window)
                        }
                        items[index].windowsOnScreen = merged
                        items[index].pid = wins.first?.ownerPID ?? items[index].pid
                        items[index].isActive = isActive(pid: items[index].pid, windows: merged)
                        let presented = presentation(appName: items[index].name, windows: merged, focus: nil)
                        items[index].label = presented.label
                        items[index].subtitle = presented.subtitle
                        items[index].profileTint = presented.tint
                    }
                } else {
                    appendWindows(wins, of: app, to: &items)
                }
                continue
            }
            if settings.groupWindows || wins.count <= 1 {
                items.append(appButton(
                    id: app.id,
                    appID: app.id,
                    name: app.name,
                    path: app.path,
                    bundleID: app.bundleID,
                    pid: pid,
                    isPinned: false,
                    followsPin: false,
                    isRunning: true,
                    windows: wins,
                    focus: wins.count == 1 ? wins.first : nil
                ))
            } else {
                for window in wins {
                    items.append(appButton(
                        id: "\(app.id)#\(window.windowID)",
                        appID: app.id,
                        name: app.name,
                        path: app.path,
                        bundleID: app.bundleID,
                        pid: pid,
                        isPinned: false,
                        followsPin: false,
                        isRunning: true,
                        windows: [window],
                        focus: window
                    ))
                }
            }
            shown.insert(app.id)
        }
        return items
    }

    private func appendWindows(_ wins: [WindowInfo], of app: LiveApp, to items: inout [AppItem]) {
        let present = Set(items.filter { $0.pinID == app.id }.flatMap { $0.windowsOnScreen.map(\.windowID) })
        for window in wins where !present.contains(window.windowID) {
            let button = appButton(
                id: "\(app.id)#\(window.windowID)",
                appID: app.id,
                name: app.name,
                path: app.path,
                bundleID: app.bundleID,
                pid: window.ownerPID,
                isPinned: false,
                followsPin: items.contains { $0.pinID == app.id && $0.appIsPinned },
                isRunning: true,
                windows: [window],
                focus: window
            )
            if let last = items.lastIndex(where: { $0.pinID == app.id }) {
                items.insert(button, at: items.index(after: last))
            } else {
                items.append(button)
            }
        }
    }

    private func appButton(
        id: String,
        appID: String,
        name: String,
        path: String,
        bundleID: String?,
        pid: pid_t?,
        isPinned: Bool,
        followsPin: Bool,
        isRunning: Bool,
        windows: [WindowInfo],
        focus: WindowInfo?
    ) -> AppItem {
        let presented = presentation(appName: name, windows: windows, focus: focus)
        return AppItem(
            id: id,
            name: name,
            path: path,
            bundleID: bundleID,
            pid: pid,
            isPinned: isPinned,
            isRunning: isRunning,
            windowsOnScreen: windows,
            isActive: isActive(pid: pid, windows: windows),
            appID: appID,
            followsPin: followsPin,
            label: presented.label,
            subtitle: presented.subtitle,
            profileTint: presented.tint
        )
    }

    private func presentation(
        appName: String,
        windows: [WindowInfo],
        focus: WindowInfo?
    ) -> (label: String, subtitle: String?, tint: ProfileTint?) {
        if let focus {
            return (
                BrowserProfile.pageTitle(focus.title, appName: appName, profile: focus.profileName),
                focus.profileName,
                settings.groupWindows ? nil : focus.profileTint
            )
        }
        if windows.count == 1, let only = windows.first {
            return (
                BrowserProfile.pageTitle(only.title, appName: appName, profile: only.profileName),
                only.profileName,
                settings.groupWindows ? nil : only.profileTint
            )
        }
        let names = windows.compactMap(\.profileName)
        let subtitle = names.count == windows.count && names.allSatisfy { $0 == names.first } ? names.first : nil
        return (appName, subtitle, nil)
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
            steerApp(pid: pid, onto: displayID, previous: previous, moveExisting: false)
            return
        }
        steerTask?.cancel()
        guard settings.openWindowsOnClickedDisplay else { return }
        steerTask = Task { @MainActor in
            let pauses: [Duration] = [.milliseconds(200), .milliseconds(300), .milliseconds(500), .milliseconds(800)]
            for pause in pauses {
                try? await Task.sleep(for: pause)
                guard !Task.isCancelled, self.settings.openWindowsOnClickedDisplay else { return }
                guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: Self.finderBundleID).first?.processIdentifier else {
                    continue
                }
                self.steerApp(pid: pid, onto: displayID, previous: [], moveExisting: false)
                return
            }
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
        relocatedWindowID = nil
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
        relocatedWindowID = window.windowID
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
        hoveredAppID = nil
    }
}
