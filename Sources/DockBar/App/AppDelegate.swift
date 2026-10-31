import AppKit
import Darwin

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let bridge = EventBridge()
    private var terminateSource: DispatchSourceSignal?
    private var interruptSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installSignalHandlers()
        let model = TaskbarModel.shared
        model.start()
        ScreenManager.shared.start()
        PreviewCoordinator.shared.start()
        bridge.start()
        DockController.hideNativeDock()
        ScreenManager.shared.bringForward()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            ScreenManager.shared.bringForward()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            ScreenManager.shared.bringForward()
        }
        if !Permissions.isAccessibilityTrusted && !UserDefaults.standard.bool(forKey: "skippedAccessibilityOnboarding") {
            SettingsWindowController.shared.showOnboarding()
        }
        let screens = NSScreen.screens.count
        Log.info("Bars ready on \(screens) screen(s)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        DockController.restoreNativeDock()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func installSignalHandlers() {
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        terminate.setEventHandler {
            NSApp.terminate(nil)
        }
        terminate.resume()
        terminateSource = terminate

        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        interrupt.setEventHandler {
            NSApp.terminate(nil)
        }
        interrupt.resume()
        interruptSource = interrupt
    }
}

@MainActor
final class EventBridge: NSObject {
    private var timer: Timer?
    private var tickCount = 0

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(refresh), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(refresh), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(refresh), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(refresh), name: NSWorkspace.didHideApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(refresh), name: NSWorkspace.didUnhideApplicationNotification, object: nil)

        let timer = Timer(timeInterval: 1, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    @objc private func refresh() {
        TaskbarModel.shared.refreshFromEvent()
    }

    @objc private func tick() {
        TaskbarModel.shared.refresh(clearance: true)
        ScreenManager.shared.bringForward()
        ScreenManager.shared.resetCursorIfOverBar()
        tickCount += 1
        if tickCount.isMultiple(of: 3) {
            DockController.enforceHidden()
        }
    }
}
