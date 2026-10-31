import AppKit

@MainActor
final class WindowHighlight {
    static let shared = WindowHighlight()

    private var panel: NSPanel?

    func show(frame: CGRect) {
        guard frame.width > 2, frame.height > 2 else {
            hide()
            return
        }
        let outset = frame.insetBy(dx: -4, dy: -4)
        let panel = ensurePanel()
        panel.setFrame(outset, display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: BarWindows.barLevel.rawValue - 1)
        panel.collectionBehavior = BarWindows.overlayBehavior
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.sharingType = .none
        let view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 10
        view.layer?.borderWidth = 3
        view.layer?.borderColor = NSColor.controlAccentColor.cgColor
        view.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
        panel.contentView = view
        self.panel = panel
        return panel
    }
}
