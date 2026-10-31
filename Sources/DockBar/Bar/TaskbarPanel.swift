import AppKit
import Darwin
import SwiftUI

enum BarCursor {
    static let trackingOptions: NSTrackingArea.Options = [
        .mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect,
    ]

    static func useArrow() {
        NSCursor.arrow.set()
    }
}

@_silgen_name("CGSNewRegionWithRect")
private func CGSNewRegionWithRect(_ rect: UnsafePointer<CGRect>, _ region: UnsafeMutablePointer<CFTypeRef?>) -> Int32

@MainActor
private enum SkyLight {
    nonisolated(unsafe) static let handle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
        RTLD_LAZY
    )

    static func setOpaqueShape(window: Int32, region: CFTypeRef) -> Int32 {
        guard let handle,
              let connection = dlsym(handle, "SLSMainConnectionID"),
              let setter = dlsym(handle, "SLSSetWindowOpaqueShape") else { return -1 }
        let connectionID = unsafeBitCast(connection, to: (@convention(c) () -> Int32).self)()
        let set = unsafeBitCast(setter, to: (@convention(c) (Int32, Int32, CFTypeRef) -> Int32).self)
        return set(connectionID, window, region)
    }
}

@MainActor
enum BarHitShape {
    /// The window server ignores nearly clear pixels when choosing the cursor.
    /// A full opaque shape makes the bar the hit target for its whole frame.
    static func apply(to window: NSWindow) {
        guard window.windowNumber > 0 else { return }
        var rect = CGRect(origin: .zero, size: window.frame.size)
        var region: CFTypeRef?
        let made = CGSNewRegionWithRect(&rect, &region)
        guard made == 0, let region else { return }
        _ = SkyLight.setOpaqueShape(window: Int32(window.windowNumber), region: region)
    }
}

/// Captures the full bar, including pixels the glass material leaves transparent,
/// so the window underneath cannot keep its resize cursor.
final class BarContentView: NSView {
    private var tracking: NSTrackingArea?

    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerForDraggedTypes(TrashDrag.types)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        if let trash = TrashDrag.trashView(in: self, at: point) { return trash }
        return super.hitTest(point) ?? self
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        TrashDrag.operation(sender, in: self)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        TrashDrag.operation(sender, in: self)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        TrashDrag.highlight(in: self, on: false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        TrashDrag.perform(sender, in: self)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: BarCursor.trackingOptions, owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        window?.invalidateCursorRects(for: self)
        BarCursor.useArrow()
    }

    override func mouseMoved(with event: NSEvent) {
        BarCursor.useArrow()
    }

    override func cursorUpdate(with event: NSEvent) {
        BarCursor.useArrow()
    }
}

final class ClearHostingView<Content: View>: NSHostingView<Content> {
    private var tracking: NSTrackingArea?

    override var isOpaque: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerForDraggedTypes(TrashDrag.types)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        if let trash = TrashDrag.trashView(in: self, at: point) { return trash }
        return super.hitTest(point) ?? self
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        TrashDrag.operation(sender, in: self)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        TrashDrag.operation(sender, in: self)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        TrashDrag.highlight(in: self, on: false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        TrashDrag.perform(sender, in: self)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: BarCursor.trackingOptions, owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        window?.invalidateCursorRects(for: self)
        BarCursor.useArrow()
    }

    override func mouseMoved(with event: NSEvent) {
        BarCursor.useArrow()
    }

    override func cursorUpdate(with event: NSEvent) {
        BarCursor.useArrow()
    }
}

enum BarWindows {
    /// Above normal, floating, and fullscreen app windows, and above the hidden Dock.
    static var barLevel: NSWindow.Level {
        NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)))
    }

    static var previewLevel: NSWindow.Level {
        NSWindow.Level(rawValue: barLevel.rawValue + 1)
    }

    static var overlayBehavior: NSWindow.CollectionBehavior {
        [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }
}

final class TaskbarPanel: NSPanel {
    init(frame: NSRect) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        // Enough alpha that the window server hit-tests the bar instead of the window behind it.
        backgroundColor = NSColor.black.withAlphaComponent(0.12)
        hasShadow = false
        ignoresMouseEvents = false
        level = BarWindows.barLevel
        collectionBehavior = BarWindows.overlayBehavior
        sharingType = .none
        hidesOnDeactivate = false
        isFloatingPanel = false
        becomesKeyOnlyIfNeeded = true
        isMovable = false
        acceptsMouseMovedEvents = true
        animationBehavior = .none
        title = "DockBar"
        let content = BarContentView(frame: frame)
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.12).cgColor
        contentView = content
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .mouseMoved, .mouseEntered, .cursorUpdate, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            BarCursor.useArrow()
        default:
            break
        }
        if event.type == .rightMouseDown, let content = contentView {
            let hit = content.hitTest(event.locationInWindow)
            if !BarContextMenu.isInteractive(hit) {
                BarContextMenu.show(in: content, at: content.convert(event.locationInWindow, from: nil))
                return
            }
        }
        super.sendEvent(event)
    }

    func install<Content: View>(_ hosting: ClearHostingView<Content>) {
        guard let content = contentView else { return }
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(effect)

        hosting.translatesAutoresizingMaskIntoConstraints = false
        hosting.wantsLayer = true
        hosting.layer?.isOpaque = false
        hosting.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.12).cgColor
        content.addSubview(hosting)
        NSLayoutConstraint.activate([
            effect.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            effect.topAnchor.constraint(equalTo: content.topAnchor),
            effect.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            hosting.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: content.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }
}

@MainActor
enum BarContextMenu {
    private final class Action: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        @objc func invoke() { run() }
    }

    private final class Hold: NSObject {
        let actions: [Action]
        init(_ actions: [Action]) { self.actions = actions }
    }

    nonisolated(unsafe) private static var token: UInt8 = 0

    static func isInteractive(_ view: NSView?) -> Bool {
        var current = view
        while let candidate = current {
            if candidate is ClickView || candidate is TrashDropView { return true }
            current = candidate.superview
        }
        return false
    }

    static func show(in view: NSView, at point: NSPoint) {
        let menu = NSMenu()
        let preferences = Action { SettingsWindowController.shared.showSettings() }
        let quit = Action { NSApp.terminate(nil) }
        let preferencesItem = NSMenuItem(title: "Preferences…", action: #selector(Action.invoke), keyEquivalent: "")
        preferencesItem.target = preferences
        let quitItem = NSMenuItem(title: "Quit and Restore Dock", action: #selector(Action.invoke), keyEquivalent: "")
        quitItem.target = quit
        menu.addItem(preferencesItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)
        objc_setAssociatedObject(menu, &token, Hold([preferences, quit]), .OBJC_ASSOCIATION_RETAIN)
        menu.popUp(positioning: nil, at: point, in: view)
    }
}
