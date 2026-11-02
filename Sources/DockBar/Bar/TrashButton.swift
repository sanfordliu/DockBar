import AppKit
import SwiftUI

struct TrashButton: View {
    private var model: TaskbarModel { .shared }
    @State private var hovered = false
    @State private var targeted = false

    private var acceptingDrop: Bool { targeted || model.trashDragHover }

    var body: some View {
        let size = model.settings.effectiveIconSize
        Image(nsImage: IconCache.shared.trashIcon(isFull: model.trashCount > 0))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .padding(BarLayout.trashInset)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(acceptingDrop ? 0.34 : (hovered ? 0.16 : 0)))
                    .padding(.horizontal, 2)
            }
            .scaleEffect(acceptingDrop ? 1.22 : 1)
            .animation(.spring(duration: 0.2), value: acceptingDrop)
            .overlay {
                TrashCatcher(
                    onHover: { hovered = $0 },
                    onOpen: { TrashService.shared.open() },
                    onEmpty: { confirmEmpty() },
                    onDrop: { urls in
                        TrashService.shared.receive(urls: urls)
                    },
                    onTarget: { targeted = $0 }
                )
            }
            .help(model.trashCount == 0 ? "Trash is empty" : "Trash, \(model.trashCount) items")
            .accessibilityLabel("Trash")
    }

    private func confirmEmpty() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Empty Trash?"
        alert.informativeText = "The items in the Trash will be deleted permanently."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Empty Trash")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            TrashService.shared.empty()
        }
    }
}

struct TrashCatcher: NSViewRepresentable {
    var onHover: (Bool) -> Void
    var onOpen: () -> Void
    var onEmpty: () -> Void
    var onDrop: ([URL]) -> Void
    var onTarget: (Bool) -> Void

    func makeNSView(context: Context) -> TrashDropView { TrashDropView() }

    func updateNSView(_ view: TrashDropView, context: Context) {
        view.onHover = onHover
        view.onOpen = onOpen
        view.onEmpty = onEmpty
        view.onDrop = onDrop
        view.onTarget = onTarget
    }
}

@MainActor
enum AppDrop {
    static func applications(on pasteboard: NSPasteboard) -> [URL] {
        var seen = Set<String>()
        return TrashDrag.urls(from: pasteboard).compactMap { url in
            guard let app = applicationURL(url) else { return nil }
            guard seen.insert(app.path).inserted else { return nil }
            return app
        }
    }

    static func applicationURL(_ url: URL) -> URL? {
        let resolvedAlias = (try? URL(resolvingAliasFileAt: url, options: [.withoutUI])) ?? url
        let resolved = resolvedAlias.resolvingSymlinksInPath()
        guard resolved.pathExtension.lowercased() == "app" else { return nil }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &directory), directory.boolValue else {
            return nil
        }
        return resolved
    }
}

@MainActor
enum TrashDrag {
    static let types: [NSPasteboard.PasteboardType] = [
        .fileURL,
        .URL,
        NSPasteboard.PasteboardType("NSFilenamesPboardType"),
    ]

    static func trashView(in root: NSView, at point: NSPoint) -> TrashDropView? {
        if let trash = root as? TrashDropView, trash.bounds.contains(point) { return trash }
        for child in root.subviews {
            let childPoint = root.convert(point, to: child)
            if let found = trashView(in: child, at: childPoint) { return found }
        }
        return nil
    }

    static func urls(from pasteboard: NSPasteboard) -> [URL] {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return urls
        }
        let legacy = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        if let paths = pasteboard.propertyList(forType: legacy) as? [String] {
            return paths.map { URL(fileURLWithPath: $0) }
        }
        return []
    }

    static func operation(_ sender: NSDraggingInfo, in view: NSView) -> NSDragOperation {
        let point = view.convert(sender.draggingLocation, from: nil)
        let over = trashView(in: view, at: point) != nil
        highlight(in: view, on: over)
        if over {
            TaskbarModel.shared.clearDropTarget()
            return .delete
        }
        let apps = AppDrop.applications(on: sender.draggingPasteboard)
        guard !apps.isEmpty else {
            TaskbarModel.shared.clearDropTarget()
            return []
        }
        if let screenPoint = screenPoint(of: sender, in: view) {
            TaskbarModel.shared.trackDrop(at: screenPoint)
        }
        return .copy
    }

    static func perform(_ sender: NSDraggingInfo, in view: NSView) -> Bool {
        highlight(in: view, on: false)
        defer { TaskbarModel.shared.clearDropTarget() }
        let point = view.convert(sender.draggingLocation, from: nil)
        if trashView(in: view, at: point) != nil {
            let urls = urls(from: sender.draggingPasteboard)
            guard !urls.isEmpty else { return false }
            TrashService.shared.receive(urls: urls)
            return true
        }
        let apps = AppDrop.applications(on: sender.draggingPasteboard)
        guard !apps.isEmpty else { return false }
        TaskbarModel.shared.pinApplications(apps, at: screenPoint(of: sender, in: view))
        return true
    }

    static func screenPoint(of sender: NSDraggingInfo, in view: NSView) -> CGPoint? {
        guard let window = view.window else { return nil }
        return window.convertToScreen(NSRect(origin: sender.draggingLocation, size: .zero)).origin
    }

    static func highlight(in root: NSView, on: Bool) {
        func walk(_ view: NSView) {
            if let trash = view as? TrashDropView { trash.onTarget(on) }
            view.subviews.forEach(walk)
        }
        walk(root)
    }
}

final class TrashDropView: NSView {
    var onHover: (Bool) -> Void = { _ in }
    var onOpen: () -> Void = {}
    var onEmpty: () -> Void = {}
    var onDrop: ([URL]) -> Void = { _ in }
    var onTarget: (Bool) -> Void = { _ in }
    private var tracking: NSTrackingArea?

    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(TrashDrag.types)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: BarCursor.trackingOptions, owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        BarCursor.useArrow()
        onHover(true)
    }

    override func mouseMoved(with event: NSEvent) {
        BarCursor.useArrow()
    }

    override func cursorUpdate(with event: NSEvent) {
        BarCursor.useArrow()
    }
    override func mouseExited(with event: NSEvent) { onHover(false) }
    override func mouseUp(with event: NSEvent) { onOpen() }
    override func mouseDown(with event: NSEvent) {}

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open Trash", action: #selector(openTrash), keyEquivalent: "")
        open.target = self
        let empty = NSMenuItem(title: "Empty Trash", action: #selector(emptyTrash), keyEquivalent: "")
        empty.target = self
        empty.isEnabled = TaskbarModel.shared.trashCount > 0
        menu.addItem(open)
        menu.addItem(empty)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 6), in: self)
    }

    @objc private func openTrash() { onOpen() }
    @objc private func emptyTrash() { onEmpty() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onTarget(true)
        return .delete
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        .delete
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onTarget(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onTarget(false)
        let urls = TrashDrag.urls(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        onDrop(urls)
        return true
    }
}
