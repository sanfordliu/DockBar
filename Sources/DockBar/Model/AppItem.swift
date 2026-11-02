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
    /// App identity used for pins. Window buttons keep this even when `id` is per window.
    var appID: String = ""
    /// Extra windows of a pinned app follow that pin when the bar is reordered.
    var followsPin: Bool = false
    /// Title shown beside the icon when labels are on.
    var label: String?
    /// Chrome profile, shown under the title.
    var subtitle: String?
    var profileTint: ProfileTint?

    var bundleURL: URL { URL(fileURLWithPath: path) }
    var pinID: String { appID.isEmpty ? id : appID }
    var appIsPinned: Bool { isPinned || followsPin }
}
