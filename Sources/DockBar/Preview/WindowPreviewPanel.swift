import AppKit
import SwiftUI

@MainActor
final class PreviewCoordinator {
    static let shared = PreviewCoordinator()

    private var panel: NSPanel?
    private var hosting: NSHostingView<WindowPreviewView>?
    private var showTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var currentAppID: String?
    private var currentDisplay: CGDirectDisplayID?
    private var globalMonitor: Any?

    private struct Pending {
        var appID: String
        var anchor: CGRect
        var displayID: CGDirectDisplayID
    }

    private var pending: Pending?

    func start() {
        guard globalMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { _ in
            Task { @MainActor in
                PreviewCoordinator.shared.hide()
            }
        }
    }

    func iconEntered(appID: String, anchor: CGRect, displayID: CGDirectDisplayID) {
        guard TaskbarModel.shared.dragID == nil else { return }
        hideTask?.cancel()
        showTask?.cancel()
        let next = Pending(appID: appID, anchor: anchor, displayID: displayID)
        guard hasWindows(next) else {
            pending = nil
            if panel?.isVisible == true { hide() }
            return
        }
        pending = next
        if panel?.isVisible == true {
            presentPending()
        } else {
            showTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                self.presentPending()
            }
        }
    }

    func iconExited() {
        showTask?.cancel()
        scheduleHide()
    }

    func show(appID: String, anchor: CGRect, displayID: CGDirectDisplayID) {
        showTask?.cancel()
        hideTask?.cancel()
        let next = Pending(appID: appID, anchor: anchor, displayID: displayID)
        guard hasWindows(next) else {
            hide()
            return
        }
        pending = next
        presentPending()
    }

    func isShowing(_ appID: String) -> Bool {
        panel?.isVisible == true && currentAppID == appID
    }

    func cancelHide() {
        hideTask?.cancel()
    }

    func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled else { return }
            self.hide()
        }
    }

    func hide() {
        showTask?.cancel()
        hideTask?.cancel()
        pending = nil
        currentAppID = nil
        WindowHighlight.shared.hide()
        panel?.orderOut(nil)
    }

    private func hasWindows(_ pending: Pending) -> Bool {
        let windows = TaskbarModel.shared.entries(for: pending.displayID)
            .first { $0.id == pending.appID }?
            .windowsOnScreen
        return windows?.isEmpty == false
    }

    private func presentPending() {
        guard let pending, hasWindows(pending) else {
            hide()
            return
        }
        let model = TaskbarModel.shared
        let row = model.entries(for: pending.displayID).first { $0.id == pending.appID }?.windowsOnScreen ?? []
        let size = panelSize(windows: row, displayID: pending.displayID)
        let origin = panelOrigin(anchor: pending.anchor, size: size, displayID: pending.displayID)
        let panel = ensurePanel()
        let root = WindowPreviewView(
            appID: pending.appID,
            displayID: pending.displayID,
            model: model,
            thumbnails: .shared
        )
        if hosting == nil || currentAppID != pending.appID || currentDisplay != pending.displayID {
            let host = NSHostingView(rootView: root)
            host.wantsLayer = true
            host.layer?.backgroundColor = NSColor.clear.cgColor
            panel.contentView = host
            hosting = host
        } else {
            hosting?.rootView = root
        }
        currentAppID = pending.appID
        currentDisplay = pending.displayID
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }

    private func panelSize(windows: [WindowInfo], displayID: CGDirectDisplayID) -> CGSize {
        let screenWidth = ScreenCoordinates.screen(for: displayID)?.frame.width ?? 800
        return PreviewLayout.size(
            windowCount: windows.count,
            showsProfile: windows.contains { $0.profileName?.isEmpty == false },
            maxWidth: screenWidth - 24
        )
    }

    private func panelOrigin(anchor: CGRect, size: CGSize, displayID: CGDirectDisplayID) -> CGPoint {
        let screen = ScreenCoordinates.screen(for: displayID)
        let minX = (screen?.frame.minX ?? 0) + 8
        let maxX = (screen?.frame.maxX ?? size.width) - size.width - 8
        let x = min(max(anchor.midX - size.width / 2, minX), max(minX, maxX))
        let barTop = (screen?.frame.minY ?? 0) + TaskbarModel.shared.settings.occupiedHeight
        let y = max(anchor.maxY + 8, barTop + 6)
        return CGPoint(x: x, y: y)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = BarWindows.previewLevel
        panel.collectionBehavior = BarWindows.overlayBehavior
        panel.hidesOnDeactivate = false
        panel.sharingType = .none
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = false
        panel.title = "DockBar Previews"
        let glass = NSHostingView(rootView: PreviewChrome())
        glass.wantsLayer = true
        glass.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = glass
        self.panel = panel
        return panel
    }
}

enum PreviewLayout {
    static let thumbnailWidth: CGFloat = 196
    static let thumbnailHeight: CGFloat = 118
    static let cardInset: CGFloat = 4
    static let cardGap: CGFloat = 8
    static let outerPadding: CGFloat = 12

    static var cardWidth: CGFloat { thumbnailWidth + cardInset * 2 }

    /// Width of the panel when every card is visible. Left and right padding are the same.
    static func width(windowCount: Int) -> CGFloat {
        guard windowCount > 0 else { return 240 }
        let cards = CGFloat(windowCount) * cardWidth
        let gaps = CGFloat(max(windowCount - 1, 0)) * cardGap
        return outerPadding * 2 + cards + gaps
    }

    static func height(showsProfile: Bool) -> CGFloat {
        let title: CGFloat = 20
        let caption: CGFloat = 16
        let profile: CGFloat = showsProfile ? 16 : 0
        return outerPadding * 2 + title + 8 + thumbnailHeight + 4 + caption + profile + cardInset * 2
    }

    static func size(windowCount: Int, showsProfile: Bool, maxWidth: CGFloat) -> CGSize {
        if windowCount == 0 { return CGSize(width: 240, height: 72) }
        let natural = width(windowCount: windowCount)
        return CGSize(width: min(natural, maxWidth), height: height(showsProfile: showsProfile))
    }
}

private struct PreviewChrome: View {
    var body: some View {
        Color.clear
            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
