import AppKit

@MainActor
final class IconCache {
    static let shared = IconCache()

    private var images: [String: NSImage] = [:]

    func icon(for path: String) -> NSImage {
        if let cached = images[path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: 128, height: 128)
        images[path] = image
        return image
    }

    func trashIcon(isFull: Bool) -> NSImage {
        let name = isFull ? "FullTrashIcon" : "TrashIcon"
        let path = "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/\(name).icns"
        if let cached = images[path] { return cached }
        let image = NSImage(contentsOfFile: path)
            ?? NSImage(systemSymbolName: "trash", accessibilityDescription: "Trash")
            ?? NSImage()
        images[path] = image
        return image
    }
}
