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
    private var queued: [CGWindowID: CGFloat] = [:]
    private var batchTask: Task<Void, Never>?
    /// Nil until a refresh says which windows still exist. Captures for other ids are dropped.
    private var kept: Set<CGWindowID>?
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
        if inFlight.contains(window.windowID) { return }
        let aspect = window.cgFrame.height > 1 ? window.cgFrame.width / window.cgFrame.height : 1.6
        queued[window.windowID] = aspect
        guard batchTask == nil else { return }
        batchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(16))
            self.batchTask = nil
            let batch = self.queued
            self.queued = [:]
            var specs: [CGWindowID: CGFloat] = [:]
            for (id, aspect) in batch where self.inFlight.insert(id).inserted {
                specs[id] = aspect
            }
            await self.capture(specs)
        }
    }

    func discardMissing(keeping ids: Set<CGWindowID>) {
        kept = ids
        images = images.filter { ids.contains($0.key) }
        fetchedAt = fetchedAt.filter { ids.contains($0.key) }
        queued = queued.filter { ids.contains($0.key) }
    }

    private func capture(_ specs: [CGWindowID: CGFloat]) async {
        guard !specs.isEmpty else { return }
        let batch = await Self.captureBatch(specs)
        for id in specs.keys {
            inFlight.remove(id)
            guard kept?.contains(id) ?? true else { continue }
            guard let box = batch.images[id] else { continue }
            images[id] = NSImage(
                cgImage: box.image,
                size: NSSize(width: box.image.width, height: box.image.height)
            )
            fetchedAt[id] = Date()
            lastError = nil
        }
        if batch.permissionDenied {
            lastError = "Window previews need Screen Recording permission."
        }
    }

    private struct CaptureBatch: Sendable {
        var images: [CGWindowID: CGImageBox]
        var permissionDenied: Bool
    }

    /// One window-server snapshot, then a capture for each window in that snapshot.
    private nonisolated static func captureBatch(_ specs: [CGWindowID: CGFloat]) async -> CaptureBatch {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            var images: [CGWindowID: CGImageBox] = [:]
            for (windowID, aspect) in specs {
                guard let window = content.windows.first(where: { $0.windowID == windowID }) else { continue }
                let height: CGFloat = 280
                let width = max(160, min(520, height * aspect))
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let configuration = SCStreamConfiguration()
                configuration.width = Int(width * 2)
                configuration.height = Int(height * 2)
                configuration.scalesToFit = true
                configuration.showsCursor = false
                do {
                    if let image = try await captureImage(filter: filter, configuration: configuration) {
                        images[windowID] = image
                    }
                } catch {
                    if !CGPreflightScreenCaptureAccess() {
                        return CaptureBatch(images: images, permissionDenied: true)
                    }
                }
            }
            return CaptureBatch(images: images, permissionDenied: false)
        } catch {
            return CaptureBatch(images: [:], permissionDenied: !CGPreflightScreenCaptureAccess())
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
