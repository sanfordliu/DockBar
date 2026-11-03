import AppKit
import Darwin
import SwiftUI

@MainActor
enum BarCursor {
    static let trackingOptions: NSTrackingArea.Options = [
        .mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect,
    ]

    /// Cursor rects are ignored while DockBar is in the background, so the resize
    /// cursor from the window above the bar stays put. This lets the bar replace it.
    static func claim(_ window: NSWindow) {
        setBool(window, "setAllowsCursorRectsWhenInactive:", true)
        if let view = window.contentView {
            window.invalidateCursorRects(for: view)
        }
    }

    static func allowsRectsWhenInactive(_ window: NSWindow) -> Bool {
        bool(window, "allowsCursorRectsWhenInactive")
    }

    static func installRects(on view: NSView) {
        let arrow = arrowRect(in: view)
        if arrow.width > 0, arrow.height > 0 { view.addCursorRect(arrow, cursor: .arrow) }
        let line = resizeLineRect(in: view)
        if line.width > 0, line.height > 0 { view.addCursorRect(line, cursor: verticalResize) }
    }

    /// The window's bottom resize line overlaps the top of the bar.
    static let resizeLine: CGFloat = 6

    /// Hosting views are flipped, so a shorter rect would keep the top and drop the bottom.
    static func arrowRect(in view: NSView) -> CGRect {
        var rect = view.bounds
        guard rect.height > resizeLine else { return .zero }
        if view.isFlipped {
            rect.origin.y += resizeLine
        }
        rect.size.height -= resizeLine
        return rect
    }

    static func resizeLineRect(in view: NSView) -> CGRect {
        var rect = view.bounds
        guard rect.height > resizeLine else { return .zero }
        rect.size.height = resizeLine
        if !view.isFlipped {
            rect.origin.y = view.bounds.maxY - resizeLine
        }
        return rect
    }

    static var verticalResize: NSCursor {
        let selector = NSSelectorFromString("_windowResizeNorthSouthCursor")
        guard NSCursor.responds(to: selector) else { return .resizeUpDown }
        let implementation = unsafeBitCast(
            NSCursor.method(for: selector),
            to: (@convention(c) (AnyClass, Selector) -> Unmanaged<NSCursor>).self
        )
        return implementation(NSCursor.self, selector).takeUnretainedValue()
    }

    static func useArrow() {
        guard NSEvent.pressedMouseButtons == 0 else { return }
        switch ScreenManager.shared.cursorIntent(at: NSEvent.mouseLocation) {
        case .arrow:
            NSCursor.arrow.set()
        case .resize:
            verticalResize.set()
        case .none:
            break
        }
    }

    static func allowBackgroundCursor() {
        SkyLight.allowBackgroundCursor()
    }

    private static func setBool(_ window: NSWindow, _ name: String, _ value: Bool) {
        let selector = NSSelectorFromString(name)
        guard window.responds(to: selector) else { return }
        let implementation = unsafeBitCast(
            window.method(for: selector),
            to: (@convention(c) (AnyObject, Selector, Bool) -> Void).self
        )
        implementation(window, selector, value)
    }

    private static func bool(_ window: NSWindow, _ name: String) -> Bool {
        let selector = NSSelectorFromString(name)
        guard window.responds(to: selector) else { return false }
        let implementation = unsafeBitCast(
            window.method(for: selector),
            to: (@convention(c) (AnyObject, Selector) -> Bool).self
        )
        return implementation(window, selector)
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

    static func allowBackgroundCursor() {
        guard let handle,
              let connection = dlsym(handle, "SLSMainConnectionID"),
              let setter = dlsym(handle, "SLSSetConnectionProperty") else { return }
        let connectionID = unsafeBitCast(connection, to: (@convention(c) () -> Int32).self)()
        let set = unsafeBitCast(
            setter,
            to: (@convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32).self
        )
        _ = set(connectionID, connectionID, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }
}

@MainActor
enum BarHitShape {
    private static var appliedSize: [Int: CGSize] = [:]

    /// The top resize strip stays out of the opaque region so the window behind the bar can be resized.
    static func apply(to window: NSWindow) {
        guard window.windowNumber > 0 else { return }
        let size = window.frame.size
        if appliedSize[window.windowNumber] == size { return }
        var rect = CGRect(x: 0, y: 0, width: size.width, height: max(0, size.height - BarCursor.resizeLine))
        var region: CFTypeRef?
        let made = CGSNewRegionWithRect(&rect, &region)
        guard made == 0, let region else { return }
        // CGSNewRegionWithRect returns a +1 region. Consume that retain so ARC releases it.
        let owned = Unmanaged<CFTypeRef>.passUnretained(region).takeRetainedValue()
        _ = SkyLight.setOpaqueShape(window: Int32(window.windowNumber), region: owned)
        appliedSize[window.windowNumber] = size
    }

    static func clear(_ window: NSWindow) {
        appliedSize.removeValue(forKey: window.windowNumber)
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
        guard bounds.contains(point), !BarCursor.resizeLineRect(in: self).contains(point) else { return nil }
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
        TaskbarModel.shared.clearDropTarget()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        TrashDrag.perform(sender, in: self)
    }

    override func resetCursorRects() {
        BarCursor.installRects(on: self)
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
    /// Lets the system label color lighten on dark glass and darken on light glass.
    override var allowsVibrancy: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerForDraggedTypes(TrashDrag.types)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point), !BarCursor.resizeLineRect(in: self).contains(point) else { return nil }
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
        TaskbarModel.shared.clearDropTarget()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        TrashDrag.perform(sender, in: self)
    }

    override func resetCursorRects() {
        BarCursor.installRects(on: self)
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
    private var glassView: NSGlassEffectView?
    private weak var hostingView: NSView?

    init(frame: NSRect) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        isReleasedWhenClosed = false
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
        BarCursor.claim(self)
        let content = BarContentView(frame: frame)
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.clear.cgColor
        contentView = content
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
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
        let glass = NSGlassEffectView()
        glass.style = .regular
        glass.cornerRadius = 0
        glass.translatesAutoresizingMaskIntoConstraints = false
        hosting.wantsLayer = true
        hosting.layer?.isOpaque = false
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        glass.contentView = hosting
        content.addSubview(glass)
        glassView = glass
        hostingView = hosting
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            glass.topAnchor.constraint(equalTo: content.topAnchor),
            glass.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    /// System glass, the same kind the Dock uses. The floating bar is a capsule; the full-width bar is a shelf.
    func applyChrome(floating: Bool) {
        backgroundColor = .clear
        hasShadow = floating
        let radius = floating ? (contentView?.bounds.height ?? frame.height) / 2 : 0
        if let content = contentView {
            content.wantsLayer = true
            content.layer?.backgroundColor = NSColor.clear.cgColor
            content.layer?.cornerRadius = radius
            content.layer?.masksToBounds = false
        }
        glassView?.cornerRadius = radius
        hostingView?.layer?.backgroundColor = NSColor.clear.cgColor
    }

    /// Pull the glass off the window so WindowServer can tear down a display without finalizing it.
    func detach() {
        BarHitShape.clear(self)
        orderOut(nil)
        glassView?.contentView = nil
        glassView?.removeFromSuperview()
        glassView = nil
        hostingView = nil
        contentView = nil
    }

    /// Finish after the display reconfiguration has finished. The panel stays out and ARC releases it.
    func shutdown() {
        detach()
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
