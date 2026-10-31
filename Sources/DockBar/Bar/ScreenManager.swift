import AppKit

@MainActor
final class ScreenManager: NSObject {
    static let shared = ScreenManager()

    private var bars: [CGDirectDisplayID: BarController] = [:]
    private var cursorTimer: Timer?

    func start() {
        BarCursor.allowBackgroundCursor()
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

    enum CursorIntent {
        case arrow, resize, none
    }

    /// Below the resize line the bar uses the arrow. On the line, and a few points above it, keep the vertical resize cursor.
    func cursorIntent(at point: CGPoint) -> CursorIntent {
        for bar in bars.values {
            let frame = bar.panel.frame
            guard point.x >= frame.minX, point.x < frame.maxX else { continue }
            let gap = frame.maxY - point.y
            if gap > BarCursor.resizeLine, gap <= frame.height {
                return .arrow
            }
            if gap >= -BarCursor.resizeLine, gap <= BarCursor.resizeLine {
                return .resize
            }
        }
        return .none
    }

    func bringForward() {
        for bar in bars.values {
            bar.bringForward()
        }
    }

    func resetCursorIfOverBar() {
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
