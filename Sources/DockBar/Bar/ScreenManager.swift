import AppKit
import CoreGraphics

@MainActor
final class ScreenManager: NSObject {
    static let shared = ScreenManager()

    private var bars: [CGDirectDisplayID: BarController] = [:]
    private var cursorTimer: Timer?
    private var restoreWork: DispatchWorkItem?
    /// Bars detached during a display reconfiguration, held until WindowServer finishes tearing down the old screens.
    private var retiring: [BarController] = []
    private var closedForCurrentReconfiguration = false
    private static var displayCallbackInstalled = false

    /// How many bars are currently shown. Used by tests.
    var barCount: Int { bars.count }

    func start() {
        BarCursor.allowBackgroundCursor()
        layout(screens: NSScreen.screens, orderFront: true)
        installCursorTimer()
        installDisplayCallback()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(spaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
        TaskbarModel.shared.onChange = { [weak self] in
            self?.layout()
        }
    }

    @objc func layout() {
        layout(screens: NSScreen.screens, orderFront: false)
    }

    @objc private func screensChanged() {
        if closedForCurrentReconfiguration {
            scheduleRestore()
            return
        }
        layout(screens: NSScreen.screens, orderFront: true)
    }

    @objc private func spaceChanged() {
        bringForward()
    }

    /// Rebuilds bars for the given screens. An empty list leaves the current bars alone so a
    /// mid-reconfiguration blank `NSScreen.screens` cannot wipe the only remaining bar.
    func layout(screens: [NSScreen], orderFront: Bool) {
        guard !screens.isEmpty else {
            Log.info("Screen list empty; keeping \(bars.count) bar(s)")
            return
        }
        finishRetiring()
        let ids = Set(screens.map(\.displayID))
        for id in bars.keys where !ids.contains(id) {
            retireBar(for: id)
        }
        for screen in screens {
            let id = screen.displayID
            if let bar = bars[id] {
                bar.layout(on: screen, model: .shared, orderFront: orderFront)
            } else {
                let bar = BarController(screen: screen, model: .shared)
                bars[id] = bar
                bar.bringForward()
            }
        }
    }

    /// Called from the CoreGraphics display reconfiguration callback on the main thread.
    func handleDisplayReconfiguration(display: CGDirectDisplayID, begin: Bool, removed: Bool) {
        if begin {
            if !closedForCurrentReconfiguration {
                closedForCurrentReconfiguration = true
                PreviewCoordinator.shared.hide()
                closeAllBars()
                Log.info("Display change began; closed bars before screens tear down")
            }
            return
        }
        if removed {
            retireBar(for: display)
        }
        scheduleRestore()
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

    func bringForwardIfNeeded() {
        for bar in bars.values {
            bar.bringForwardIfNeeded()
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
        restoreWork?.cancel()
        restoreWork = nil
        closedForCurrentReconfiguration = false
        cursorTimer?.invalidate()
        cursorTimer = nil
        closeAllBars()
        finishRetiring()
    }

    @objc private func enforceCursor() {
        resetCursorIfOverBar()
    }

    private func closeAllBars() {
        let dying = Array(bars.values)
        bars.removeAll()
        for bar in dying {
            bar.detach()
            retiring.append(bar)
        }
    }

    private func retireBar(for id: CGDirectDisplayID) {
        guard let bar = bars.removeValue(forKey: id) else { return }
        bar.detach()
        retiring.append(bar)
    }

    private func finishRetiring() {
        let done = retiring
        retiring = []
        for bar in done {
            bar.shutdown()
        }
    }

    private func scheduleRestore() {
        restoreWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.closedForCurrentReconfiguration = false
            self.layout(screens: NSScreen.screens, orderFront: true)
            Log.info("Bars ready on \(NSScreen.screens.count) screen(s) after display change")
        }
        restoreWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func installDisplayCallback() {
        guard !Self.displayCallbackInstalled else { return }
        let error = CGDisplayRegisterReconfigurationCallback(Self.displayCallback, nil)
        if error == .success {
            Self.displayCallbackInstalled = true
        } else {
            Log.error("Could not watch display changes (\(error.rawValue))")
        }
    }

    private nonisolated static let displayCallback: CGDisplayReconfigurationCallBack = { display, flags, _ in
        let begin = flags.contains(.beginConfigurationFlag)
        let removed = flags.contains(.removeFlag)
        let deliver = {
            MainActor.assumeIsolated {
                ScreenManager.shared.handleDisplayReconfiguration(
                    display: display,
                    begin: begin,
                    removed: removed
                )
            }
        }
        if Thread.isMainThread {
            deliver()
        } else {
            DispatchQueue.main.sync(execute: deliver)
        }
    }
}
