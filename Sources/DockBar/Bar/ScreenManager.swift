import AppKit
import CoreGraphics

@MainActor
final class ScreenManager: NSObject {
    static let shared = ScreenManager()

    private var bars: [CGDirectDisplayID: BarController] = [:]
    private var cursorTimer: Timer?
    private var restoreWork: DispatchWorkItem?
    private var retireCleanupWork: DispatchWorkItem?
    /// Bars for displays that went away. Kept alive past WindowServer's device teardown.
    private var retiring: [BarController] = []
    private var reconfiguring = false
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
        // Model refresh must not create glass panels while WindowServer is still
        // tearing devices down (reconnect crashes in SLSDeviceDestroy otherwise).
        if reconfiguring {
            scheduleRestore()
            return
        }
        layout(screens: NSScreen.screens, orderFront: false)
    }

    @objc private func screensChanged() {
        if reconfiguring {
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
    func layout(screens: [NSScreen], orderFront: Bool, forceDuringReconfiguration: Bool = false) {
        if reconfiguring && !forceDuringReconfiguration {
            scheduleRestore()
            return
        }
        guard !screens.isEmpty else {
            Log.info("Screen list empty; keeping \(bars.count) bar(s)")
            return
        }
        let ids = Set(screens.map(\.displayID))
        for id in bars.keys where !ids.contains(id) {
            softRetire(for: id)
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
            hideBarsForDisplayChange()
            return
        }
        if removed {
            softRetire(for: display)
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
        retireCleanupWork?.cancel()
        retireCleanupWork = nil
        reconfiguring = false
        cursorTimer?.invalidate()
        cursorTimer = nil
        for bar in bars.values {
            bar.panel.orderOut(nil)
        }
        bars.removeAll()
        // Drop retiring on the next turn so we are not inside WindowServer's teardown.
        let leftover = retiring
        retiring = []
        DispatchQueue.main.async {
            for bar in leftover {
                bar.panel.orderOut(nil)
            }
        }
    }

    @objc private func enforceCursor() {
        resetCursorIfOverBar()
    }

    /// On the first begin wave, abandon every bar panel with orderOut only.
    /// Do not call SLSSetWindowOpaqueShape here — that crashes during begin
    /// (`__CGSWindowSetOpaqueShape_block_invoke`). Later waves orderOut leftovers.
    private func hideBarsForDisplayChange() {
        let already = reconfiguring
        reconfiguring = true
        PreviewCoordinator.shared.hide()
        if !already {
            let dying = Array(bars.values)
            bars.removeAll()
            for bar in dying {
                // orderOut only — do not tear down glass or call SkyLight during begin.
                bar.panel.orderOut(nil)
                retiring.append(bar)
            }
            scheduleRetireCleanup()
            Log.info("Display change began; abandoned \(dying.count) bar(s)")
            return
        }
        for bar in bars.values {
            bar.panel.orderOut(nil)
        }
    }

    private func softRetire(for id: CGDirectDisplayID) {
        guard let bar = bars.removeValue(forKey: id) else { return }
        bar.panel.orderOut(nil)
        retiring.append(bar)
        scheduleRetireCleanup()
    }

    private func scheduleRetireCleanup() {
        retireCleanupWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Drop retains only. Do not message the panels — their CGS windows may already
            // have been finalized with the old display devices.
            self.retiring = []
        }
        retireCleanupWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0, execute: work)
    }

    private func scheduleRestore() {
        restoreWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reconfiguring = false
            self.layout(screens: NSScreen.screens, orderFront: true, forceDuringReconfiguration: true)
            Log.info("Bars ready on \(NSScreen.screens.count) screen(s) after display change")
        }
        restoreWork = work
        // Connect brings monitors up in multiple waves; wait for them to settle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
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
        let fromMain = Thread.isMainThread
        let run: @MainActor @Sendable () -> Void = {
            ScreenManager.shared.handleDisplayReconfiguration(
                display: display,
                begin: begin,
                removed: removed
            )
        }
        if fromMain {
            MainActor.assumeIsolated(run)
        } else if begin {
            // Must hide before WindowServer tears the device down.
            DispatchQueue.main.sync { MainActor.assumeIsolated(run) }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated(run) }
        }
    }
}
