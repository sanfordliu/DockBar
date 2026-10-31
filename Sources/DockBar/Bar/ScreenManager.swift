import AppKit

@MainActor
final class ScreenManager: NSObject {
    static let shared = ScreenManager()

    private var bars: [CGDirectDisplayID: BarController] = [:]
    private var cursorTimer: Timer?

    func start() {
        layout()
        installCursorTimer()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(layout),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        TaskbarModel.shared.onChange = { [weak self] in
            self?.layout()
        }
    }

    @objc func layout() {
        let screens = NSScreen.screens
        let ids = Set(screens.map(\.displayID))
        for id in bars.keys where !ids.contains(id) {
            bars[id]?.panel.orderOut(nil)
            bars[id] = nil
        }
        for screen in screens {
            let id = screen.displayID
            if let bar = bars[id] {
                bar.layout(on: screen, model: .shared)
            } else {
                let bar = BarController(screen: screen, model: .shared)
                bars[id] = bar
                bar.bringForward()
            }
        }
    }

    func bringForward() {
        for bar in bars.values {
            bar.bringForward()
        }
    }

    func resetCursorIfOverBar(at point: CGPoint = NSEvent.mouseLocation) {
        guard bars.values.contains(where: { $0.panel.frame.contains(point) }) else { return }
        BarCursor.useArrow()
    }

    private func installCursorTimer() {
        guard cursorTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, target: self, selector: #selector(enforceCursor), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        cursorTimer = timer
    }

    func stop() {
        cursorTimer?.invalidate()
        cursorTimer = nil
        for bar in bars.values {
            bar.panel.orderOut(nil)
        }
        bars.removeAll()
    }

    @objc private func enforceCursor() {
        resetCursorIfOverBar()
    }
}
