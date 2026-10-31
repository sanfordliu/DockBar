import AppKit
import Foundation

enum DockPinsReader {
    static func read() -> [Pin] {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.apple.dock.plist")
        return read(from: url)
    }

    static func read(from url: URL) -> [Pin] {
        guard
            let data = try? Data(contentsOf: url),
            let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let apps = root["persistent-apps"] as? [[String: Any]]
        else {
            return []
        }

        var pins: [Pin] = []
        var seen = Set<String>()
        for tile in apps {
            guard let tileData = tile["tile-data"] as? [String: Any] else { continue }
            let bundleID = tileData["bundle-identifier"] as? String
            let label = tileData["file-label"] as? String
            var path: String?
            if let fileData = tileData["file-data"] as? [String: Any],
               let raw = fileData["_CFURLString"] as? String {
                path = filePath(from: raw)
            }
            if path == nil, let bundleID,
               let resolved = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                path = resolved.resolvingSymlinksInPath().path
            }
            guard let path else { continue }
            let name = label ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            let pin = Pin(path: path, bundleID: bundleID, name: name)
            guard seen.insert(pin.id).inserted else { continue }
            pins.append(pin)
        }
        return pins
    }

    private static func filePath(from raw: String) -> String? {
        if let url = URL(string: raw), url.isFileURL, !url.path.isEmpty {
            return url.path
        }
        if raw.hasPrefix("/") { return raw }
        if raw.hasPrefix("file://") {
            let stripped = String(raw.dropFirst("file://".count))
            return stripped.removingPercentEncoding ?? stripped
        }
        return nil
    }
}
