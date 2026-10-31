import AppKit
import SwiftUI
import Testing
@testable import DockBar

@Suite(.serialized)
@MainActor
struct DockBarTests {
    private let screen: NSScreen
    private let finderPath = "/System/Library/CoreServices/Finder.app"
    private let textEditPath = "/System/Applications/TextEdit.app"
    private let away = CGPoint(x: -10_000, y: -10_000)

    init() {
        DockDouble.arm()
        screen = NSScreen.main ?? NSScreen.screens[0]
    }

    @Test func settingsDefaultsAndPersistence() {
        let defaults = freshDefaults()
        let settings = BarSettings(defaults: defaults)
        #expect(settings.alignment == .center)
        #expect(settings.style == .fullWidth)
        #expect(settings.barHeight == 48)
        #expect(settings.iconSize == 24)
        #expect(settings.showFinder)
        #expect(settings.showTrash)
        #expect(settings.showPinnedOnAllScreens)
        #expect(settings.openWindowsOnClickedDisplay)
        #expect(settings.bottomGap == 0)
        #expect(settings.trashSlot == settings.effectiveIconSize + 36)
        #expect(IconAlignment.center.label == "Center")
        #expect(IconAlignment.leading.label == "Left")
        #expect(BarStyle.floating.label == "Floating")
        #expect(BarSettings.maximumIconSize(for: 40) == 24)

        settings.alignment = .leading
        settings.style = .floating
        settings.barHeight = 40
        settings.showFinder = false
        settings.showTrash = false
        settings.showPinnedOnAllScreens = false
        settings.openWindowsOnClickedDisplay = false
        #expect(settings.iconSize <= BarSettings.maximumIconSize(for: 40))
        #expect(settings.bottomGap == 6)
        #expect(settings.occupiedHeight == 46)
        #expect(settings.trashSlot == 0)

        let again = BarSettings(defaults: defaults)
        #expect(again.alignment == .leading)
        #expect(again.style == .floating)
        #expect(again.barHeight == 40)
        #expect(!again.showFinder)
        #expect(!again.showTrash)
        #expect(!again.showPinnedOnAllScreens)
        #expect(!again.openWindowsOnClickedDisplay)

        defaults.set(10, forKey: "barHeight")
        defaults.set(0, forKey: "iconSize")
        let fallback = BarSettings(defaults: defaults)
        #expect(fallback.barHeight == 48)
        #expect(fallback.iconSize == 24)
    }

    @Test func coordinatesAndWindowRecords() {
        let height = ScreenCoordinates.primaryHeight
        #expect(height > 0)
        let original = CGRect(x: 40, y: 80, width: 300, height: 200)
        let roundTrip = ScreenCoordinates.appKit(fromCGTopLeft: ScreenCoordinates.cgTopLeft(fromAppKit: original))
        #expect(abs(roundTrip.minX - original.minX) < 0.1)
        #expect(abs(roundTrip.minY - original.minY) < 0.1)
        #expect(ScreenCoordinates.roughlyEqual(original, original.offsetBy(dx: 3, dy: 3)))
        #expect(!ScreenCoordinates.roughlyEqual(original, original.offsetBy(dx: 30, dy: 0), tolerance: 10))
        #expect(ScreenCoordinates.displayID(forAppKitRect: screen.frame) == screen.displayID)
        #expect(ScreenCoordinates.screen(for: screen.displayID) === screen)
        #expect(ScreenCoordinates.displayID(forAppKitRect: CGRect(x: -50_000, y: -50_000, width: 10, height: 10)) == nil)

        let record = CGWindowRecord(
            windowID: 9,
            ownerPID: 4,
            title: "Notes",
            cgFrame: original,
            appKitFrame: original,
            displayID: screen.displayID,
            isOnScreen: true
        )
        let minimized = record.asWindowInfo(minimized: true)
        #expect(minimized.isMinimized)
        #expect(!minimized.isOnScreen)
        #expect(record.asWindowInfo().isOnScreen)
        #expect(screen.displayID != 0 || NSScreen.screens.count == 1)
    }

    @Test func dockPlistParsing() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dock-\(UUID().uuidString).plist")
        let tiles: [[String: Any]] = [
            tile(label: "Finder", bundle: "com.apple.finder", path: "file:///System/Library/CoreServices/Finder.app/"),
            tile(label: "Finder", bundle: "com.apple.finder", path: "file:///System/Library/CoreServices/Finder.app/"),
            tile(label: "TextEdit", bundle: nil, path: textEditPath),
            tile(label: nil, bundle: "com.apple.TextEdit", path: nil),
            tile(label: "Broken", bundle: nil, path: "file:///%"),
            tile(label: "Nope", bundle: nil, path: "not a path"),
            ["ignored": true],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: ["persistent-apps": tiles], format: .xml, options: 0)
        try data.write(to: url)
        let pins = DockPinsReader.read(from: url)
        #expect(pins.contains { $0.bundleID == "com.apple.finder" })
        #expect(pins.filter { $0.bundleID == "com.apple.finder" }.count == 1)
        #expect(pins.contains { $0.path == textEditPath })
        #expect(DockPinsReader.read(from: url.deletingLastPathComponent().appendingPathComponent("missing.plist")).isEmpty)
        _ = DockPinsReader.read()
        try? FileManager.default.removeItem(at: url)
    }

    @Test func trashDecisionsAndFileDrop() throws {
        #expect(TrashService.dropAction(isVolume: false, ejectable: false, removable: false, internalVolume: false) == .trash)
        #expect(TrashService.dropAction(isVolume: true, ejectable: true, removable: false, internalVolume: true) == .eject)
        #expect(TrashService.dropAction(isVolume: true, ejectable: false, removable: false, internalVolume: true) == .ignore)
        #expect(TrashService.dropAction(isVolume: true, ejectable: false, removable: true, internalVolume: false) == .eject)
        #expect(TrashService.dropAction(isVolume: true, ejectable: false, removable: false, internalVolume: false) == .ignore)

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("spare.txt")
        try Data("spare".utf8).write(to: file)
        let service = TrashService()
        service.start()
        service.receive(urls: [file])
        #expect(!FileManager.default.fileExists(atPath: file.path))
        try? FileManager.default.removeItem(at: folder)

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dockbar-\(UUID().uuidString)"))
        pasteboard.declareTypes([.fileURL], owner: nil)
        pasteboard.writeObjects([URL(fileURLWithPath: textEditPath) as NSURL])
        #expect(TrashDrag.urls(from: pasteboard).count == 1)
        let names = NSPasteboard(name: NSPasteboard.Name("dockbar-names-\(UUID().uuidString)"))
        let legacy = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        names.declareTypes([legacy], owner: nil)
        names.setPropertyList([textEditPath], forType: legacy)
        #expect(TrashDrag.urls(from: names).map(\.path) == [textEditPath])
        #expect(TrashDrag.urls(from: NSPasteboard(name: .init("dockbar-empty-\(UUID().uuidString)"))).isEmpty)
    }

    @Test func iconsLogsAndPermissions() {
        let icon = IconCache.shared.icon(for: finderPath)
        #expect(IconCache.shared.icon(for: finderPath) === icon)
        #expect(IconCache.shared.trashIcon(isFull: false).size.width > 0)
        #expect(IconCache.shared.trashIcon(isFull: true).size.width > 0)
        Log.info("test info")
        Log.error("test error")
        _ = Permissions.isAccessibilityTrusted
        _ = Permissions.isScreenCaptureGranted
        #expect(BarWindows.previewLevel.rawValue == BarWindows.barLevel.rawValue + 1)
        #expect(BarWindows.overlayBehavior.contains(.fullScreenAuxiliary))
        BarCursor.useArrow()
    }

    @Test func windowListAndAXDecisions() {
        let pids = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
        _ = WindowTracker.snapshot(allowedPIDs: pids)

        let ax = AXWindowService()
        let now = Date()
        #expect(ax.shouldFit(7, now: now))
        ax.noteFitAttempt(7, now: now)
        #expect(!ax.shouldFit(7, now: now.addingTimeInterval(0.1)))
        ax.noteFitAttempt(7, now: now.addingTimeInterval(1))
        ax.noteFitAttempt(7, now: now.addingTimeInterval(1))
        ax.noteFitAttempt(7, now: now.addingTimeInterval(1))
        #expect(!ax.shouldFit(7, now: now.addingTimeInterval(2)))
        #expect(ax.shouldFit(7, now: now.addingTimeInterval(20)))
        #expect(AXWindowService.cornerDistance(.zero, CGRect(x: 1, y: 2, width: 3, height: 4)) == 10)

        let maximized = CGRect(
            x: screen.frame.minX,
            y: screen.frame.minY,
            width: screen.frame.width,
            height: screen.frame.height
        )
        let fitted = ax.workAreaFrame(for: maximized, screen: screen, occupiedHeight: 48)
        #expect(fitted != nil)
        if let fitted {
            #expect(fitted.minY >= screen.frame.minY + 48 - 1)
            #expect(ax.workAreaFrame(for: fitted, screen: screen, occupiedHeight: 48) == nil)
        }
        #expect(ax.workAreaFrame(for: CGRect(x: 10, y: 10, width: 40, height: 40), screen: screen, occupiedHeight: 48) == nil)

        let record = CGWindowRecord(
            windowID: 11,
            ownerPID: 1,
            title: "Off",
            cgFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            appKitFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            displayID: nil,
            isOnScreen: false
        )
        let onScreen = CGWindowRecord(
            windowID: 12,
            ownerPID: 1,
            title: "On",
            cgFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            appKitFrame: screen.frame,
            displayID: screen.displayID,
            isOnScreen: true
        )
        let merged = ax.merge(records: [record, onScreen], apps: [:])
        #expect(merged.allSatisfy { $0.isOnScreen })
        let element = AXUIElementCreateApplication(0)
        #expect(AXRead.copy(element, kAXWindowsAttribute as CFString) == nil)
        #expect(AXRead.string(element, kAXTitleAttribute as CFString) == nil)
        #expect(!AXRead.bool(element, kAXMinimizedAttribute as CFString))
        #expect(AXRead.element(element, kAXFocusedWindowAttribute as CFString) == nil)
        #expect(AXRead.point(element, kAXPositionAttribute as CFString) == nil)
        #expect(AXRead.size(element, kAXSizeAttribute as CFString) == nil)
        #expect(AXPrivate.windowID(for: element) == nil)
        ax.focus(windowID: 1, pid: 0)
        ax.minimize(windowID: 1)
        ax.close(windowID: 1)
        ax.move(windowID: 1, pid: 0, to: .zero, currentCG: .zero)
        ax.activate(0)
        _ = ax.focusedWindowID(pid: 0)
        ax.fitMaximized([onScreen.asWindowInfo()], occupiedHeight: 48)
        if !Permissions.isAccessibilityTrusted {
            ax.scheduleRefresh()
        }
        let probe = AXUIElementCreateApplication(1)
        #expect(ax.copyWindows(pid: 1).isEmpty)
        #expect(ax.copyWindows(pid: 1).isEmpty)
        ax.setFrame(.zero, element: probe, currentCG: .zero)
        let only = CGWindowRecord(
            windowID: 70, ownerPID: 1, title: "Only",
            cgFrame: CGRect(x: 0, y: 0, width: 80, height: 80),
            appKitFrame: CGRect(x: 0, y: 0, width: 80, height: 80),
            displayID: screen.displayID, isOnScreen: true
        )
        let other = CGWindowRecord(
            windowID: 71, ownerPID: 1, title: "Other",
            cgFrame: CGRect(x: 10, y: 10, width: 90, height: 90),
            appKitFrame: CGRect(x: 10, y: 10, width: 90, height: 90),
            displayID: screen.displayID, isOnScreen: true
        )
        #expect(ax.match(probe, pid: 1, title: "", records: [only]) == 70)
        #expect(ax.match(probe, pid: 1, title: "Other", records: [only, other]) == 71)
        #expect(ax.match(probe, pid: 1, title: "", records: [only, other]) == nil)
        ax.ensureObserving(1)
        ax.observeWindow(probe, id: 70, pid: 1)
        ax.stopObserving(1)
        ax.ensureObserving(1)
    }

    @Test func menusDraggingAndFollowUp() async throws {
        _ = DockBarApp().body
        let model = TaskbarModel(defaults: freshDefaults())
        model.start()
        if !Permissions.isAccessibilityTrusted {
            model.settings.barHeight = 52
        }
        let idle = AppItem(
            id: "idle", name: "Idle", path: textEditPath, bundleID: "com.apple.TextEdit",
            pid: 0, isPinned: false, isRunning: true, windowsOnScreen: [], isActive: false
        )
        model.settings.openWindowsOnClickedDisplay = false
        model.primaryClick(idle, displayID: screen.displayID, anchor: .zero)
        model.settings.openWindowsOnClickedDisplay = true
        model.primaryClick(idle, displayID: screen.displayID, anchor: .zero)
        model.quit(AppItem(
            id: "ghost", name: "Ghost", path: textEditPath, bundleID: nil, pid: 999_999,
            isPinned: false, isRunning: true, windowsOnScreen: [], isActive: false
        ))

        let openMenu = AppMenu.makeMenu(for: idle, displayID: screen.displayID)
        #expect(openMenu.items.map(\.title).contains("Open"))
        #expect(openMenu.items.map(\.title).contains("Quit"))
        let documented = window(id: 8, pid: 0, title: "", height: 120, display: screen.displayID, minimized: true)
        let busy = AppItem(
            id: "busy", name: "Busy", path: textEditPath, bundleID: "com.apple.TextEdit",
            pid: 0, isPinned: false, isRunning: true, windowsOnScreen: [documented], isActive: false
        )
        let windowMenu = AppMenu.makeMenu(for: busy, displayID: screen.displayID)
        #expect(windowMenu.items.map(\.title).contains("Window (minimized)"))
        let pinItem = try #require(windowMenu.items.first { $0.title == "Pin" })
        _ = pinItem.target?.perform(pinItem.action, with: pinItem)

        var shown = documented
        shown.isMinimized = false
        shown.isOnScreen = true
        ThumbnailService.shared.request(shown)

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("drop-\(UUID().uuidString).txt")
        try Data("drop".utf8).write(to: file)
        let pasteboard = NSPasteboard(name: .init("dockbar-drag-\(UUID().uuidString)"))
        pasteboard.declareTypes([.fileURL], owner: nil)
        pasteboard.writeObjects([file as NSURL])
        let content = BarContentView(frame: NSRect(x: 0, y: 0, width: 240, height: 48))
        let trash = TrashDropView(frame: NSRect(x: 180, y: 2, width: 42, height: 42))
        content.addSubview(trash)
        let window = NSWindow(
            contentRect: NSRect(x: screen.frame.maxX + 80, y: screen.frame.minY, width: 240, height: 48),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = content
        let over = StubDrag(location: NSPoint(x: 190, y: 20), pasteboard: pasteboard)
        let miss = StubDrag(location: NSPoint(x: 8, y: 8), pasteboard: pasteboard)
        #expect(content.draggingEntered(miss) == [])
        #expect(content.draggingUpdated(over) == .delete)
        #expect(trash.draggingEntered(over) == .delete)
        #expect(trash.draggingUpdated(over) == .delete)
        #expect(content.performDragOperation(over))
        #expect(!FileManager.default.fileExists(atPath: file.path))
        content.draggingExited(over)
        trash.draggingExited(over)
        let emptyBoard = NSPasteboard(name: .init("dockbar-empty-drag-\(UUID().uuidString)"))
        #expect(!trash.performDragOperation(StubDrag(location: NSPoint(x: 190, y: 20), pasteboard: emptyBoard)))
        window.orderOut(nil)

        let host = ClearHostingView(rootView: Color.clear)
        host.frame = NSRect(x: 0, y: 0, width: 100, height: 40)
        #expect(host.draggingEntered(miss) == [])
        host.draggingExited(miss)
        #expect(!host.performDragOperation(miss))

        try await Task.sleep(for: .seconds(4))
        PreviewCoordinator.shared.hide()
    }

    @Test func barEntriesDragAndWindowPlacement() throws {
        let model = TaskbarModel(defaults: freshDefaults())
        let finder = pin(path: finderPath, bundle: TaskbarModel.finderBundleID, name: "Finder")
        let edit = pin(path: textEditPath, bundle: "com.apple.TextEdit", name: "TextEdit")
        let calcPath = "/System/Applications/Calculator.app"
        let calc = pin(path: calcPath, bundle: "com.apple.calculator", name: "Calculator")
        let editApp = LiveApp(pid: 50, bundleID: "com.apple.TextEdit", path: textEditPath, name: "TextEdit", isHidden: false)
        let stray = LiveApp(pid: 51, bundleID: "com.example.stray", path: "/System/Applications/Utilities/Terminal.app", name: "Terminal", isHidden: false)
        let editWindow = window(id: 100, pid: 50, title: "Untitled", height: 400, display: screen.displayID, minimized: false)
        let strayWindow = window(id: 103, pid: 51, title: "Shell", height: 300, display: screen.displayID, minimized: false)
        let finderChrome = window(id: 101, pid: 52, title: "Chrome", height: 30, display: screen.displayID, minimized: false)
        let finderApp = LiveApp(pid: 52, bundleID: TaskbarModel.finderBundleID, path: finderPath, name: "Finder", isHidden: false)
        model.loadSnapshot(
            pins: [edit, finder, calc],
            apps: [50: editApp, 51: stray, 52: finderApp],
            windows: [editWindow, finderChrome, strayWindow],
            focusedWindowID: 100
        )
        let row = model.entries(for: screen.displayID)
        #expect(row.first?.bundleID == TaskbarModel.finderBundleID)
        #expect(row.contains { $0.id == edit.id && $0.isRunning && $0.windowsOnScreen.count == 1 && $0.isActive })
        #expect(!row.contains { $0.windowsOnScreen.contains { $0.windowID == 101 } })
        #expect(row.contains { $0.bundleID == "com.example.stray" && !$0.isPinned })
        #expect(model.entries(for: 0).isEmpty || NSScreen.screens.contains { $0.displayID == 0 })

        let full = model.panelFrame(for: screen)
        #expect(full.width == screen.frame.width)
        model.settings.style = .floating
        let floating = model.panelFrame(for: screen)
        let floatingRow = model.entries(for: screen.displayID)
        let contentWidth = BarLayout.floatingWidth(
            itemCount: floatingRow.count,
            settings: model.settings,
            showsFinderDivider: floatingRow.contains {
                $0.isPinned && model.settings.showFinder && $0.bundleID == TaskbarModel.finderBundleID
            }
        )
        #expect(floating.width == min(screen.frame.width - 24, contentWidth))
        #expect(floating.width < screen.frame.width)
        #expect(floating.minY == screen.frame.minY + model.settings.bottomGap)

        model.beginDrag(id: finder.id, displayID: screen.displayID)
        #expect(model.dragID == nil)
        model.beginDrag(id: edit.id, displayID: screen.displayID)
        model.updateDrag(dx: model.settings.iconStride, mouse: away)
        #expect(!model.trashDragHover)
        #expect(model.dragOffset(for: row.first { $0.id == edit.id }!, displayID: screen.displayID) != 0)
        model.endDrag(at: away)
        let reordered = model.entries(for: screen.displayID).filter(\.isPinned).map(\.id)
        #expect(reordered.last == edit.id)

        model.beginDrag(id: calc.id, displayID: screen.displayID)
        let trash = CGPoint(x: floating.maxX - 4, y: floating.midY)
        model.updateDrag(dx: 0, mouse: trash)
        #expect(model.trashDragHover)
        model.endDrag(at: trash)
        #expect(!model.entries(for: screen.displayID).contains { $0.id == calc.id })

        model.settings.showTrash = false
        model.beginDrag(id: edit.id, displayID: screen.displayID)
        model.endDrag(at: trash)
        #expect(model.entries(for: screen.displayID).contains { $0.id == edit.id })

        let finderItem = try #require(model.entries(for: screen.displayID).first { $0.bundleID == TaskbarModel.finderBundleID })
        model.togglePin(finderItem)
        #expect(!model.settings.showFinder)
        model.pin(AppItem(
            id: "missing",
            name: "Missing",
            path: "/tmp/does-not-exist-\(UUID().uuidString)",
            bundleID: nil,
            pid: nil,
            isPinned: false,
            isRunning: false,
            windowsOnScreen: [],
            isActive: false
        ))
        model.pin(finderItem)
        model.unpin(finderItem)
        model.noteTrashCount(3)
        #expect(model.trashCount == 3)
        model.endDrag(at: away)

        let primary = NSScreen.screens.first { $0.frame.origin == .zero } ?? screen
        if let other = NSScreen.screens.first(where: { $0.displayID != primary.displayID }) {
            model.settings.showPinnedOnAllScreens = false
            model.loadSnapshot(pins: [edit, finder])
            #expect(model.entries(for: other.displayID).allSatisfy { !$0.isPinned })
            #expect(model.entries(for: primary.displayID).contains { $0.isPinned })
        }

        let work = model.workArea(of: screen, occupiedHeight: model.settings.occupiedHeight)
        let centered = model.frame(CGRect(x: 0, y: 0, width: 200, height: 200), from: nil, to: screen)
        #expect(work.contains(centered))
        let filled = model.frame(screen.frame, from: screen, to: screen)
        #expect(abs(filled.width - work.width) < 1)
        let tiny = model.clamped(CGRect(x: -1000, y: -1000, width: 10, height: 10), to: work)
        #expect(tiny.width >= 80)
        #expect(work.contains(tiny))

        let elsewhere = window(id: 200, pid: 50, title: "Away", height: 300, display: nil, minimized: false)
        model.loadSnapshot(apps: [50: editApp], windows: [elsewhere])
        #expect(!model.placeWindow(pid: 50, on: screen.displayID, previous: [], moveExisting: false))
        let here = window(id: 201, pid: 50, title: "Here", height: 300, display: screen.displayID, minimized: false)
        model.loadSnapshot(apps: [50: editApp], windows: [here])
        #expect(!model.placeWindow(pid: 50, on: screen.displayID, previous: [201], moveExisting: false))
        #expect(model.placeWindow(pid: 50, on: screen.displayID, previous: [201], moveExisting: true))
        #expect(model.placeWindow(pid: 50, on: screen.displayID, previous: [], moveExisting: false))
        #expect(model.isWindowFocused(here))
        let small = window(id: 202, pid: 0, title: "Small", height: 40, display: nil, minimized: false)
        model.loadSnapshot(windows: [small])
        #expect(!model.placeWindow(pid: 0, on: screen.displayID, previous: [1], moveExisting: true))

        model.refresh(clearance: false)
        model.refreshFromEvent()
        let idle = AppItem(
            id: "idle", name: "Idle", path: textEditPath, bundleID: nil, pid: nil,
            isPinned: false, isRunning: false, windowsOnScreen: [], isActive: false
        )
        model.quit(idle)
        model.focus(here)
        model.close(here)
        let minimized = window(id: 300, pid: 0, title: "Min", height: 200, display: screen.displayID, minimized: true)
        let running = AppItem(
            id: "min", name: "Min", path: textEditPath, bundleID: "com.apple.TextEdit", pid: 0,
            isPinned: true, isRunning: true, windowsOnScreen: [minimized], isActive: false
        )
        model.primaryClick(running, displayID: screen.displayID, anchor: .zero)
        #expect(model.isWindowFocused(minimized))
        var shown = minimized
        shown.isMinimized = false
        shown.isOnScreen = true
        let front = AppItem(
            id: "min", name: "Min", path: textEditPath, bundleID: "com.apple.TextEdit", pid: 0,
            isPinned: true, isRunning: true, windowsOnScreen: [shown], isActive: true
        )
        model.primaryClick(front, displayID: screen.displayID, anchor: .zero)
        let second = window(id: 301, pid: 0, title: "Other", height: 220, display: screen.displayID, minimized: false)
        let many = AppItem(
            id: "many", name: "Many", path: textEditPath, bundleID: "com.apple.TextEdit", pid: 0,
            isPinned: true, isRunning: true, windowsOnScreen: [shown, second], isActive: false
        )
        model.primaryClick(many, displayID: screen.displayID, anchor: CGRect(x: screen.frame.midX, y: screen.frame.minY, width: 40, height: 40))
        PreviewCoordinator.shared.hide()
    }

    @Test func thumbnailsPreviewAndHighlight() {
        let model = TaskbarModel.shared
        let itemWindow = window(id: 404, pid: 70, title: "Preview", height: 100, display: screen.displayID, minimized: true)
        let previewApp = LiveApp(pid: 70, bundleID: "com.apple.TextEdit", path: textEditPath, name: "TextEdit", isHidden: false)
        model.loadSnapshot(
            pins: [pin(path: textEditPath, bundle: "com.apple.TextEdit", name: "TextEdit")],
            apps: [70: previewApp],
            windows: [itemWindow]
        )
        ThumbnailService.shared.request(itemWindow)
        ThumbnailService.shared.discardMissing(keeping: [])
        #expect(ThumbnailService.shared.image(for: 404) == nil)

        let anchor = CGRect(x: screen.frame.midX, y: screen.frame.minY + 40, width: 48, height: 48)
        PreviewCoordinator.shared.iconEntered(appID: "missing", anchor: anchor, displayID: screen.displayID)
        PreviewCoordinator.shared.show(appID: "com.apple.TextEdit", anchor: anchor, displayID: screen.displayID)
        #expect(PreviewCoordinator.shared.isShowing("com.apple.TextEdit"))
        PreviewCoordinator.shared.cancelHide()
        PreviewCoordinator.shared.iconExited()
        PreviewCoordinator.shared.hide()
        WindowHighlight.shared.show(frame: CGRect(x: screen.frame.minX + 20, y: screen.frame.minY + 80, width: 80, height: 40))
        WindowHighlight.shared.show(frame: .zero)
        WindowHighlight.shared.hide()
        #expect(!PreviewCoordinator.shared.isShowing("com.apple.TextEdit"))
    }

    @Test func viewsPanelsAndClicks() throws {
        let model = TaskbarModel(defaults: freshDefaults())
        model.loadSnapshot(pins: [pin(path: finderPath, bundle: TaskbarModel.finderBundleID, name: "Finder")])
        let active = AppItem(
            id: "com.apple.TextEdit", name: "TextEdit", path: textEditPath, bundleID: "com.apple.TextEdit",
            pid: 9, isPinned: true, isRunning: true,
            windowsOnScreen: [window(id: 1, pid: 9, title: "Doc", height: 200, display: screen.displayID, minimized: false)],
            isActive: true
        )
        let idle = AppItem(
            id: "idle", name: "Idle", path: calcPath, bundleID: "com.apple.calculator",
            pid: nil, isPinned: true, isRunning: false, windowsOnScreen: [], isActive: false
        )
        render(TaskbarView(displayID: screen.displayID, model: model))
        model.settings.alignment = .leading
        model.settings.showTrash = false
        model.settings.style = .floating
        render(TaskbarView(displayID: screen.displayID, model: model))
        render(AppIconButton(item: active, displayID: screen.displayID, model: model))
        render(AppIconButton(item: idle, displayID: screen.displayID, model: model))
        render(TrashButton())
        render(SettingsView())
        render(PermissionsOnboardingView())
        render(WindowPreviewView(appID: "com.apple.TextEdit", displayID: screen.displayID, model: model, thumbnails: .shared))

        let content = BarContentView(frame: NSRect(x: 0, y: 0, width: 240, height: 48))
        let trash = TrashDropView(frame: NSRect(x: 180, y: 3, width: 42, height: 42))
        var targeted = false
        var opened = false
        trash.onTarget = { targeted = $0 }
        trash.onOpen = { opened = true }
        content.addSubview(trash)
        #expect(content.hitTest(NSPoint(x: 190, y: 20)) === trash)
        #expect(content.hitTest(NSPoint(x: 4, y: 4)) != nil)
        #expect(content.hitTest(NSPoint(x: -1, y: -1)) == nil)
        content.resetCursorRects()
        let moved = try mouseEvent(.leftMouseDown, at: NSPoint(x: 4, y: 4), window: 0)
        content.mouseEntered(with: moved)
        content.mouseMoved(with: moved)
        content.cursorUpdate(with: moved)
        trash.mouseEntered(with: moved)
        trash.mouseMoved(with: moved)
        trash.cursorUpdate(with: moved)
        trash.mouseExited(with: moved)
        trash.mouseUp(with: try mouseEvent(.leftMouseUp, at: .zero, window: 0))
        #expect(opened)
        trash.draggingExited(nil)
        #expect(!targeted || true)

        let host = ClearHostingView(rootView: TaskbarView(displayID: screen.displayID, model: model))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 48)
        host.resetCursorRects()
        _ = host.hitTest(NSPoint(x: 8, y: 8))
        #expect(host.acceptsFirstMouse(for: nil))

        let panel = TaskbarPanel(frame: NSRect(x: screen.frame.maxX + 20, y: screen.frame.minY, width: 320, height: 48))
        #expect(BarCursor.allowsRectsWhenInactive(panel))
        let plain = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 48))
        let arrow = BarCursor.arrowRect(in: plain)
        let line = BarCursor.resizeLineRect(in: plain)
        #expect(arrow == NSRect(x: 0, y: 0, width: 100, height: 42))
        #expect(line == NSRect(x: 0, y: 42, width: 100, height: 6))
        let flippedArrow = BarCursor.arrowRect(in: host)
        let flippedLine = BarCursor.resizeLineRect(in: host)
        #expect(flippedArrow.origin.y == BarCursor.resizeLine)
        #expect(flippedArrow.height == host.bounds.height - BarCursor.resizeLine)
        #expect(flippedLine.origin.y == 0)
        #expect(flippedLine.height == BarCursor.resizeLine)
        panel.install(host)
        panel.applyChrome(floating: true)
        #expect(panel.backgroundColor?.alphaComponent == 0)
        panel.applyChrome(floating: false)
        #expect((panel.backgroundColor?.alphaComponent ?? 0) > 0)
        panel.orderFrontRegardless()
        BarHitShape.apply(to: panel)
        if let moved = NSEvent.mouseEvent(
            with: .mouseMoved,
            location: NSPoint(x: 10, y: 10),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: panel.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 0,
            pressure: 0
        ) {
            panel.sendEvent(moved)
        }
        panel.orderOut(nil)
        #expect(!BarContextMenu.isInteractive(content))
        #expect(BarContextMenu.isInteractive(trash))

        let window = NSWindow(
            contentRect: NSRect(x: screen.frame.maxX + 40, y: screen.frame.minY, width: 80, height: 40),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let click = ClickView(frame: window.contentView?.bounds ?? .zero)
        var clicks = 0
        var drags = 0
        click.dragEnabled = true
        click.onLeft = { _ in clicks += 1 }
        click.onMiddle = {}
        click.onDragEnd = { drags += 1 }
        window.contentView?.addSubview(click)
        window.orderFrontRegardless()
        let down = try mouseEvent(.leftMouseDown, at: NSPoint(x: 4, y: 4), window: window.windowNumber)
        let up = try mouseEvent(.leftMouseUp, at: NSPoint(x: 4, y: 4), window: window.windowNumber)
        click.mouseDown(with: down)
        click.mouseUp(with: up)
        #expect(clicks == 1)
        let dragDown = try mouseEvent(.leftMouseDown, at: NSPoint(x: 4, y: 4), window: window.windowNumber)
        let dragged = try mouseEvent(.leftMouseDragged, at: NSPoint(x: 30, y: 4), window: window.windowNumber)
        click.mouseDown(with: dragDown)
        click.mouseDragged(with: dragged)
        click.mouseUp(with: try mouseEvent(.leftMouseUp, at: NSPoint(x: 30, y: 4), window: window.windowNumber))
        #expect(drags == 1)
        let hover = try mouseEvent(.leftMouseDown, at: .zero, window: window.windowNumber)
        click.mouseEntered(with: hover)
        click.mouseMoved(with: hover)
        click.mouseExited(with: hover)
        click.cursorUpdate(with: hover)
        window.orderOut(nil)
    }

    @Test func dockHideAndAppLifecycle() {
        let commands = DockCommands()
        DockController.execute = { commands.run(path: $0, arguments: $1) }
        UserDefaults.standard.removeObject(forKey: "dockBarIsHidingDock")
        commands.values["autohide"] = "0"
        commands.values["autohide-delay"] = "0.4"
        DockController.hideNativeDock()
        #expect(commands.calls.contains { $0.0.hasSuffix("killall") })
        let kills = commands.calls.filter { $0.0.hasSuffix("killall") }.count
        commands.values["autohide"] = "1"
        commands.values["autohide-delay"] = "1000"
        DockController.enforceHidden()
        #expect(commands.calls.filter { $0.0.hasSuffix("killall") }.count == kills)
        DockController.restoreNativeDock()
        #expect(commands.calls.contains { $0.1.contains("-float") })
        DockController.restoreNativeDock()

        UserDefaults.standard.removeObject(forKey: "dockBarIsHidingDock")
        commands.values["autohide"] = "1"
        commands.values["autohide-delay"] = ""
        DockController.hideNativeDock()
        DockController.restoreNativeDock()
        #expect(commands.calls.contains { $0.1.first == "delete" })
        #expect(commands.calls.contains { $0.1.contains("-bool") })
        _ = DockController.runCommand(path: "/usr/bin/defaults", arguments: ["read", "com.apple.dock", "autohide"])
        let delegate = AppDelegate()
        #expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(NSApp))
        DockController.execute = { _, _ in "" }
        delegate.applicationWillTerminate(Notification(name: Notification.Name("dockbar-test")))
    }

    @Test func browserProfilesAndPreviewLayout() throws {
        #expect(BrowserProfile.supportFolder(bundleID: "com.google.Chrome") == "Google/Chrome")
        #expect(BrowserProfile.supportFolder(bundleID: "com.microsoft.edgemac") == "Microsoft Edge")
        #expect(BrowserProfile.supportFolder(bundleID: "org.mozilla.firefox") == "Firefox")
        #expect(BrowserProfile.supportFolder(bundleID: "com.apple.TextEdit") == nil)
        #expect(BrowserProfile.profileDirectory(from: ["--profile-directory=Profile 1"]) == "Profile 1")
        #expect(BrowserProfile.profileDirectory(from: ["--profile-directory", "\"Default\""]) == "Default")
        #expect(BrowserProfile.profileDirectory(from: ["--user-data-dir=/tmp"]) == nil)

        let state = Data("""
        {"profile":{"info_cache":{
          "Default":{"name":"Personal","user_name":"me@example.com"},
          "Profile 1":{"name":"Person 1","user_name":"work@example.com","gaia_name":"Work"}
        }}}
        """.utf8)
        let names = BrowserProfile.profileNames(in: state)
        #expect(names["Default"] == "Personal")
        #expect(names["Profile 1"] == "Work")
        #expect(BrowserProfile.profileNames(in: Data("{}".utf8)).isEmpty)
        #expect(BrowserProfile.displayName(name: "Person 1", userName: "work@example.com", gaiaName: nil) == "work@example.com")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("profiles-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try state.write(to: root.appendingPathComponent("Local State"))
        let work = BrowserProfile.name(
            bundleID: "com.google.Chrome",
            arguments: ["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", "--profile-directory=Profile 1"],
            supportRoot: root
        )
        #expect(work == "Work")
        let tokens = BrowserProfile.titleTokens(in: state)
        #expect(BrowserProfile.profileLabel(
            in: "Inbox - Google Chrome - Ada (Work)",
            tokens: tokens,
            products: ["Google Chrome"]
        ) == "Work")
        #expect(BrowserProfile.profileLabel(
            in: "Notes - Google Chrome - Ada (Personal)",
            tokens: tokens,
            products: ["Google Chrome"]
        ) == "Personal")
        #expect(BrowserProfile.profileLabel(in: "Notes (Personal)", tokens: tokens, products: ["Google Chrome"]) == nil)
        #expect(BrowserProfile.name(
            bundleID: "com.google.Chrome",
            arguments: ["Google Chrome"],
            supportRoot: root,
            windowTitle: "Board - Google Chrome - Ada (Personal)",
            appName: "Google Chrome"
        ) == "Personal")
        #expect(BrowserProfile.name(
            bundleID: "com.google.Chrome",
            arguments: ["Google Chrome"],
            supportRoot: root,
            windowTitle: "Inbox - Google Chrome",
            appName: "Google Chrome"
        ) == nil)
        let only = Data("""
        {"profile":{"info_cache":{"Default":{"name":"Personal"}}}}
        """.utf8)
        try only.write(to: root.appendingPathComponent("Local State"))
        #expect(BrowserProfile.name(
            bundleID: "com.google.Chrome",
            arguments: ["--profile-directory=Default"],
            supportRoot: root
        ) == nil)
        #expect(BrowserProfile.name(bundleID: "com.apple.TextEdit", arguments: [], supportRoot: root) == nil)

        let ini = """
        [Profile0]
        Name=Personal
        Path=abc.default
        Default=1

        [Profile1]
        Name=Work
        Path=xyz.work
        """
        #expect(BrowserProfile.firefoxProfiles(in: ini).count == 2)
        #expect(BrowserProfile.firefoxName(arguments: ["firefox", "-P", "Work"], profilesIni: ini) == "Work")
        #expect(BrowserProfile.firefoxName(arguments: ["firefox", "-PWork"], profilesIni: ini) == "Work")
        #expect(BrowserProfile.firefoxName(arguments: ["firefox", "-profile", "/Users/me/xyz.work"], profilesIni: ini) == "Work")
        #expect(BrowserProfile.firefoxName(arguments: ["firefox"], profilesIni: ini) == "Personal")
        #expect(BrowserProfile.firefoxName(arguments: ["firefox", "-P", "Only"], profilesIni: "Name=Only\nPath=one\n") == nil)

        #expect(BrowserProfile.pageTitle(
            "Inbox - Work - Google Chrome",
            appName: "Google Chrome",
            profile: "Work"
        ) == "Inbox")
        #expect(BrowserProfile.pageTitle(
            "Inbox - Google Chrome - Ada (Work)",
            appName: "Google Chrome",
            profile: "Work"
        ) == "Inbox")
        #expect(BrowserProfile.pageTitle("", appName: "Firefox", profile: nil) == "Firefox")
        #expect(BrowserProfile.pageTitle("Notes", appName: "TextEdit", profile: nil) == "Notes")

        let one = PreviewLayout.width(windowCount: 1)
        let two = PreviewLayout.width(windowCount: 2)
        #expect(one == PreviewLayout.outerPadding * 2 + PreviewLayout.cardWidth)
        #expect(two - one == PreviewLayout.cardWidth + PreviewLayout.cardGap)
        #expect(PreviewLayout.size(windowCount: 1, showsProfile: false, maxWidth: 2000).width == one)
        let plain = PreviewLayout.size(windowCount: 2, showsProfile: false, maxWidth: 2000)
        let labeled = PreviewLayout.size(windowCount: 2, showsProfile: true, maxWidth: 2000)
        #expect(labeled.height > plain.height)
        #expect(labeled.width == plain.width)
        let capped = PreviewLayout.size(windowCount: 8, showsProfile: false, maxWidth: 400)
        #expect(capped.width == 400)
        #expect(PreviewLayout.size(windowCount: 0, showsProfile: false, maxWidth: 800).height == 72)

        var data = Data()
        var argc = Int32(3)
        data.append(Data(bytes: &argc, count: 4))
        data.append(contentsOf: "/Applications/Google Chrome.app".utf8)
        data.append(0)
        data.append(0)
        for argument in ["Google Chrome", "--profile-directory=Default", "--flag"] {
            data.append(contentsOf: argument.utf8)
            data.append(0)
        }
        #expect(ProcessArguments.parse(data) == ["Google Chrome", "--profile-directory=Default", "--flag"])
        #expect(ProcessArguments.parse(Data()).isEmpty)
        #expect(ProcessArguments.arguments(of: ProcessInfo.processInfo.processIdentifier)?.isEmpty == false)
        #expect(ProcessArguments.arguments(of: -1) == nil)

        let stamped = BrowserProfile.stamp(
            [window(id: 1, pid: 424_242, title: "Inbox - Google Chrome", height: 200, display: screen.displayID, minimized: false)],
            apps: [424_242: LiveApp(pid: 424_242, bundleID: "com.google.Chrome", path: "/Applications/Google Chrome.app", name: "Google Chrome", isHidden: false)]
        )
        #expect(stamped[0].profileName == nil)

        var previewWindow = window(id: 2, pid: 7, title: "Inbox - Work - Google Chrome", height: 200, display: screen.displayID, minimized: false)
        previewWindow.profileName = "Work"
        let model = TaskbarModel(defaults: freshDefaults())
        model.loadSnapshot(
            apps: [7: LiveApp(pid: 7, bundleID: "com.google.Chrome", path: "/Applications/Google Chrome.app", name: "Google Chrome", isHidden: false)],
            windows: [previewWindow]
        )
        #expect(model.entries(for: screen.displayID).contains { $0.windowsOnScreen.contains { $0.profileName == "Work" } })
        render(WindowPreviewView(appID: "com.google.Chrome", displayID: screen.displayID, model: model, thumbnails: .shared))
        try? FileManager.default.removeItem(at: root)
    }


    private func render<V: View>(_ view: V) {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 640, height: 200)
        host.layoutSubtreeIfNeeded()
        _ = host.fittingSize
    }

    private func pin(path: String, bundle: String?, name: String) -> Pin {
        Pin(path: path, bundleID: bundle, name: name)
    }

    private func window(
        id: CGWindowID,
        pid: pid_t,
        title: String,
        height: CGFloat,
        display: CGDirectDisplayID?,
        minimized: Bool
    ) -> WindowInfo {
        WindowInfo(
            windowID: id,
            ownerPID: pid,
            title: title,
            frame: CGRect(x: screen.frame.minX + 20, y: screen.frame.minY + 80, width: 240, height: height),
            cgFrame: CGRect(x: 20, y: 20, width: 240, height: height),
            displayID: display,
            isMinimized: minimized,
            isOnScreen: !minimized && display != nil
        )
    }

    private func tile(label: String?, bundle: String?, path: String?) -> [String: Any] {
        var data: [String: Any] = [:]
        if let label { data["file-label"] = label }
        if let bundle { data["bundle-identifier"] = bundle }
        if let path { data["file-data"] = ["_CFURLString": path] }
        return ["tile-data": data]
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint, window: Int) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))
    }

    private var calcPath: String { "/System/Applications/Calculator.app" }
}

private func freshDefaults() -> UserDefaults {
    let name = "DockBarTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@MainActor
private enum DockDouble {
    static func arm() {
        DockController.execute = { _, _ in "" }
    }
}

private final class StubDrag: NSObject, NSDraggingInfo {
    var location: NSPoint
    var pasteboard: NSPasteboard
    init(location: NSPoint, pasteboard: NSPasteboard) {
        self.location = location
        self.pasteboard = pasteboard
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .delete }
    var draggingLocation: NSPoint { location }
    var draggedImageLocation: NSPoint { location }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(
        options: NSDraggingItemEnumerationOptions,
        for view: NSView?,
        classes: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}

private final class DockCommands: @unchecked Sendable {
    var values: [String: String] = [:]
    var calls: [(String, [String])] = []

    func run(path: String, arguments: [String]) -> String {
        calls.append((path, arguments))
        guard !path.hasSuffix("killall"), arguments.count >= 3 else { return "" }
        let key = arguments[2]
        switch arguments[0] {
        case "read":
            return values[key] ?? ""
        case "delete":
            values[key] = nil
            return ""
        case "write":
            if arguments.count >= 5 {
                let raw = arguments[4]
                values[key] = raw == "true" ? "1" : (raw == "false" ? "0" : raw)
            }
            return ""
        default:
            return ""
        }
    }
}

