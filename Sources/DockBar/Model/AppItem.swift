import Foundation

struct Pin: Codable, Equatable, Identifiable {
    var path: String
    var bundleID: String?
    var name: String

    var id: String { bundleID ?? path }
}

struct LiveApp: Equatable, Identifiable, Sendable {
    var pid: pid_t
    var bundleID: String?
    var path: String
    var name: String
    var isHidden: Bool

    var id: String { bundleID ?? path }
}

struct AppItem: Identifiable, Equatable {
    var id: String
    var name: String
    var path: String
    var bundleID: String?
    var pid: pid_t?
    var isPinned: Bool
    var isRunning: Bool
    var windowsOnScreen: [WindowInfo]
    var isActive: Bool

    var bundleURL: URL { URL(fileURLWithPath: path) }
}
