import AppKit
import CoreGraphics
import Foundation
import Observation
import ScreenCaptureKit

private final class CGImageBox: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

@MainActor
@Observable
final class ThumbnailService {
    static let shared = ThumbnailService()

    private(set) var images: [CGWindowID: NSImage] = [:]
    private var fetchedAt: [CGWindowID: Date] = [:]
    private var inFlight: Set<CGWindowID> = []
    private(set) var lastError: String?

    func image(for windowID: CGWindowID) -> NSImage? {
        images[windowID]
    }

    func request(_ window: WindowInfo) {
        guard !window.isMinimized else { return }
        if let fetched = fetchedAt[window.windowID],
           images[window.windowID] != nil,
           Date().timeIntervalSince(fetched) < 4 {
            return
        }
        guard inFlight.insert(window.windowID).inserted else { return }
        let windowID = window.windowID
        let aspect = window.cgFrame.height > 1 ? window.cgFrame.width / window.cgFrame.height : 1.6
        Task { @MainActor in
            defer { self.inFlight.remove(windowID) }
            if let box = await Self.capture(windowID: windowID, aspect: aspect) {
                let image = NSImage(
                    cgImage: box.image,
                    size: NSSize(width: box.image.width, height: box.image.height)
                )
                self.images[windowID] = image
                self.fetchedAt[windowID] = Date()
                self.lastError = nil
            }
        }
    }

    func discardMissing(keeping ids: Set<CGWindowID>) {
        images = images.filter { ids.contains($0.key) }
        fetchedAt = fetchedAt.filter { ids.contains($0.key) }
    }

    private nonisolated static func capture(windowID: CGWindowID, aspect: CGFloat) async -> CGImageBox? {
        let height: CGFloat = 280
        let width = max(160, min(520, height * aspect))
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else { return nil }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let configuration = SCStreamConfiguration()
            configuration.width = Int(width * 2)
            configuration.height = Int(height * 2)
            configuration.scalesToFit = true
            configuration.showsCursor = false
            return try await captureImage(filter: filter, configuration: configuration)
        } catch {
            await MainActor.run {
                ThumbnailService.shared.lastError = "Window previews need Screen Recording permission."
            }
            return nil
        }
    }

    private nonisolated static func captureImage(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws -> CGImageBox? {
        try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: image.map(CGImageBox.init))
                }
            }
        }
    }
}
