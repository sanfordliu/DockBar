import AppKit

@MainActor
final class BarController {
    let displayID: CGDirectDisplayID
    let panel: TaskbarPanel

    init(screen: NSScreen, model: TaskbarModel) {
        displayID = screen.displayID
        panel = TaskbarPanel(frame: model.panelFrame(for: screen))
        let hosting = ClearHostingView(rootView: TaskbarView(displayID: displayID, model: model))
        panel.install(hosting)
        panel.applyChrome(floating: model.settings.style == .floating)
    }

    func layout(on screen: NSScreen, model: TaskbarModel, orderFront: Bool = false) {
        let frame = model.panelFrame(for: screen)
        let frameChanged = panel.frame.integral != frame.integral
        if frameChanged {
            panel.setFrame(frame, display: true)
        }
        panel.applyChrome(floating: model.settings.style == .floating)
        if orderFront {
            bringForward()
        } else {
            bringForwardIfNeeded()
        }
    }

    func bringForwardIfNeeded() {
        guard panel.level != BarWindows.barLevel
            || panel.collectionBehavior != BarWindows.overlayBehavior
            || !panel.isVisible
        else { return }
        bringForward()
    }

    func bringForward() {
        panel.level = BarWindows.barLevel
        panel.collectionBehavior = BarWindows.overlayBehavior
        panel.orderFrontRegardless()
        BarCursor.claim(panel)
    }

}
