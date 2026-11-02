import AppKit
import SwiftUI

struct AppIconButton: View {
    var item: AppItem
    var displayID: CGDirectDisplayID
    var model: TaskbarModel

    var body: some View {
        let size = model.settings.effectiveIconSize
        let pad: CGFloat = 5
        let offset = model.dragOffset(for: item, displayID: displayID) + model.dropGapOffset(for: item, displayID: displayID)
        let draggingThis = model.dragID == item.id
        let showWell = model.dragID == nil && model.hoveredAppID == item.id
        Image(nsImage: IconCache.shared.icon(for: item.path))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .opacity(item.isRunning ? 1 : 0.55)
            .padding(pad)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(showWell ? 0.16 : 0))
                    .padding(.horizontal, 3)
            }
            .overlay(alignment: .bottom) {
                Capsule()
                    .fill(item.isActive ? Color.accentColor : Color.primary.opacity(0.72))
                    .frame(width: item.isActive ? 16 : 4, height: 3)
                    .padding(.bottom, 1)
                    .opacity(item.windowsOnScreen.isEmpty ? 0 : 1)
            }
            .frame(width: model.settings.iconStride, height: model.settings.barHeight - 6)
            .scaleEffect(showWell && !draggingThis ? 1.08 : 1)
        .animation(draggingThis ? nil : .spring(duration: 0.22), value: showWell)
        .offset(x: offset)
        .animation(draggingThis || model.dragID == nil ? nil : .spring(duration: 0.22), value: offset)
        .zIndex(model.dragID == item.id ? 2 : 0)
        .overlay {
            ClickCatcher(
                dragEnabled: item.isPinned && !(model.settings.showFinder && item.bundleID == TaskbarModel.finderBundleID),
                onLeft: { rect in
                    model.primaryClick(item, displayID: displayID, anchor: rect)
                },
                onMiddle: { model.newWindow(for: item, on: displayID) },
                onRight: { view in
                    AppMenu.popUp(for: item, displayID: displayID, in: view)
                },
                onHover: { inside, rect in
                    if inside {
                        model.setHoveredApp(item.id)
                        PreviewCoordinator.shared.iconEntered(appID: item.id, anchor: rect, displayID: displayID)
                    } else {
                        model.clearHoveredApp(item.id)
                        PreviewCoordinator.shared.iconExited()
                    }
                },
                onDragBegan: { model.beginDrag(id: item.id, displayID: displayID) },
                onDrag: { model.updateDrag(dx: $0) },
                onDragEnd: { model.endDrag() }
            )
        }
        .accessibilityLabel(item.name)
    }
}

struct ClickCatcher: NSViewRepresentable {
    var dragEnabled: Bool
    var onLeft: (CGRect) -> Void
    var onMiddle: () -> Void
    var onRight: (NSView) -> Void
    var onHover: (Bool, CGRect) -> Void
    var onDragBegan: () -> Void
    var onDrag: (CGFloat) -> Void
    var onDragEnd: () -> Void

    func makeNSView(context: Context) -> ClickView {
        ClickView()
    }

    func updateNSView(_ view: ClickView, context: Context) {
        view.dragEnabled = dragEnabled
        view.onLeft = onLeft
        view.onMiddle = onMiddle
        view.onRight = onRight
        view.onHover = onHover
        view.onDragBegan = onDragBegan
        view.onDrag = onDrag
        view.onDragEnd = onDragEnd
    }
}

final class ClickView: NSView {
    var dragEnabled = false
    var onLeft: (CGRect) -> Void = { _ in }
    var onMiddle: () -> Void = {}
    var onRight: (NSView) -> Void = { _ in }
    var onHover: (Bool, CGRect) -> Void = { _, _ in }
    var onDragBegan: () -> Void = {}
    var onDrag: (CGFloat) -> Void = { _ in }
    var onDragEnd: () -> Void = {}

    private var tracking: NSTrackingArea?
    private var downX: CGFloat = 0
    private var dragging = false
    private var moved = false
    private var handledMouseDown = false
    /// Tests replace this so a click can finish without a physical mouse button.
    var leftButtonIsDown: () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 }
    /// Tests supply tracking events. Production reads them from the window.
    var trackingEvent: ((NSWindow) -> NSEvent?)?

    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        BarCursor.useArrow()
        onHover(true, screenFrame)
    }

    override func mouseMoved(with event: NSEvent) {
        BarCursor.useArrow()
    }

    override func cursorUpdate(with event: NSEvent) {
        BarCursor.useArrow()
    }

    override func mouseExited(with event: NSEvent) {
        onHover(false, .zero)
    }

    override func mouseDown(with event: NSEvent) {
        downX = event.locationInWindow.x
        dragging = false
        moved = false
        handledMouseDown = false
        if event.modifierFlags.contains(.option) {
            onMiddle()
            moved = true
            return
        }
        // A background app does not receive mouseDragged. While the button is held, pull the
        // events directly so the icon can follow the pointer.
        guard let window = event.window, leftButtonIsDown() else { return }
        handledMouseDown = true
        let mask: NSEvent.EventTypeMask = [.leftMouseDragged, .leftMouseUp]
        while true {
            let next: NSEvent?
            if let trackingEvent {
                next = trackingEvent(window)
            } else {
                next = window.nextEvent(
                    matching: mask,
                    until: Date().addingTimeInterval(1.0 / 60.0),
                    inMode: .eventTracking,
                    dequeue: true
                )
            }
            if let next {
                if next.type == .leftMouseUp { break }
                follow(next)
            } else if !leftButtonIsDown() {
                if trackingEvent == nil {
                    _ = window.nextEvent(
                        matching: .leftMouseUp,
                        until: Date(),
                        inMode: .eventTracking,
                        dequeue: true
                    )
                }
                break
            }
        }
        finishLeftGesture()
    }

    override func mouseDragged(with event: NSEvent) {
        follow(event)
    }

    override func mouseUp(with event: NSEvent) {
        if handledMouseDown {
            handledMouseDown = false
            return
        }
        finishLeftGesture()
    }

    private func finishLeftGesture() {
        if dragging {
            onDragEnd()
        } else if !moved {
            onLeft(screenFrame)
        }
        dragging = false
    }

    private func follow(_ event: NSEvent) {
        let dx = event.locationInWindow.x - downX
        guard dragEnabled, abs(dx) > 4 else { return }
        if !dragging {
            dragging = true
            onDragBegan()
        }
        moved = true
        onDrag(dx)
    }

    override func rightMouseDown(with event: NSEvent) {
        onRight(self)
    }

    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 { onMiddle() }
    }

    private var screenFrame: CGRect {
        guard let window else { return .zero }
        return window.convertToScreen(convert(bounds, to: nil))
    }
}

enum AppMenu {
    private final class Action: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        @objc func invoke() { run() }
    }

    private final class ActionHold: NSObject {
        let actions: [Action]
        init(_ actions: [Action]) { self.actions = actions }
    }

    @MainActor
    static func popUp(for item: AppItem, displayID: CGDirectDisplayID, in view: NSView) {
        let menu = makeMenu(for: item, displayID: displayID)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 6), in: view)
    }

    @MainActor
    static func makeMenu(for item: AppItem, displayID: CGDirectDisplayID) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        var actions: [Action] = []

        let header = NSMenuItem(title: item.name, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if item.windowsOnScreen.isEmpty {
            add(menu, title: "Open", actions: &actions) {
                TaskbarModel.shared.launch(item, on: displayID)
            }
        } else {
            for window in item.windowsOnScreen {
                let name = window.title.isEmpty ? "Window" : window.title
                let title = window.isMinimized ? "\(name) (minimized)" : name
                let entry = add(menu, title: title, actions: &actions) {
                    TaskbarModel.shared.focus(window)
                }
                entry.state = TaskbarModel.shared.isWindowFocused(window) ? .on : .off
            }
        }

        menu.addItem(.separator())
        add(menu, title: "New Window", actions: &actions) {
            TaskbarModel.shared.newWindow(for: item, on: displayID)
        }
        add(menu, title: item.isPinned ? "Unpin" : "Pin", actions: &actions) {
            TaskbarModel.shared.togglePin(item)
        }
        add(menu, title: "Show in Finder", actions: &actions) {
            TaskbarModel.shared.reveal(item)
        }
        if item.isRunning {
            menu.addItem(.separator())
            add(menu, title: "Quit", actions: &actions) {
                TaskbarModel.shared.quit(item)
            }
        }

        objc_setAssociatedObject(menu, &MenuAssociation.token, ActionHold(actions), .OBJC_ASSOCIATION_RETAIN)
        return menu
    }

    @MainActor
    @discardableResult
    private static func add(
        _ menu: NSMenu,
        title: String,
        actions: inout [Action],
        handler: @escaping () -> Void
    ) -> NSMenuItem {
        let action = Action(handler)
        actions.append(action)
        let item = NSMenuItem(title: title, action: #selector(Action.invoke), keyEquivalent: "")
        item.target = action
        menu.addItem(item)
        return item
    }
}

private enum MenuAssociation {
    nonisolated(unsafe) static var token: UInt8 = 0
}
