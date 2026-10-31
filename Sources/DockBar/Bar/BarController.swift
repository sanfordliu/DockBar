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

    func layout(on screen: NSScreen, model: TaskbarModel) {
        let frame = model.panelFrame(for: screen)
        if panel.frame.integral != frame.integral {
            panel.setFrame(frame, display: true)
        }
        panel.applyChrome(floating: model.settings.style == .floating)
        bringForward()
    }

    func bringForward() {
        panel.level = BarWindows.barLevel
        panel.collectionBehavior = BarWindows.overlayBehavior
        panel.orderFrontRegardless()
        BarCursor.claim(panel)
        BarHitShape.apply(to: panel)
    }
}
