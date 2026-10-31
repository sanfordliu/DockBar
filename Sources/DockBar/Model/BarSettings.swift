import CoreGraphics
import Foundation
import Observation

enum IconAlignment: String, CaseIterable, Identifiable {
    case center
    case leading

    var id: String { rawValue }
    var label: String { self == .center ? "Center" : "Left" }
}

enum BarStyle: String, CaseIterable, Identifiable {
    case fullWidth
    case floating

    var id: String { rawValue }
    var label: String { self == .fullWidth ? "Full Width" : "Floating" }
}

@MainActor
@Observable
final class BarSettings {
    @ObservationIgnored var onChange: (() -> Void)?

    var alignment: IconAlignment {
        didSet { persist() }
    }
    var style: BarStyle {
        didSet { persist() }
    }
    var barHeight: CGFloat {
        didSet {
            let limit = Self.maximumIconSize(for: barHeight)
            if iconSize > limit { iconSize = limit }
            persist()
        }
    }
    var iconSize: CGFloat {
        didSet { persist() }
    }
    var showPinnedOnAllScreens: Bool {
        didSet { persist() }
    }
    var showFinder: Bool {
        didSet { persist() }
    }
    var showTrash: Bool {
        didSet { persist() }
    }
    /// Move a window onto the display whose DockBar button was clicked.
    var openWindowsOnClickedDisplay: Bool {
        didSet { persist() }
    }

    /// Icon drawn in the bar. Stays inside the chosen bar height.
    var effectiveIconSize: CGFloat { min(iconSize, Self.maximumIconSize(for: barHeight)) }
    var iconStride: CGFloat { effectiveIconSize + 10 }
    var bottomGap: CGFloat { style == .floating ? 6 : 0 }
    var occupiedHeight: CGFloat { barHeight + bottomGap }
    var trashSlot: CGFloat { showTrash ? effectiveIconSize + 36 : 0 }

    static func maximumIconSize(for barHeight: CGFloat) -> CGFloat {
        max(16, barHeight - 16)
    }

    private let defaults: UserDefaults
    private var ready = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        alignment = IconAlignment(rawValue: defaults.string(forKey: "alignment") ?? "") ?? .center
        style = BarStyle(rawValue: defaults.string(forKey: "barStyle") ?? "") ?? .fullWidth
        let storedHeight = defaults.double(forKey: "barHeight")
        let height: CGFloat = storedHeight >= 40 ? CGFloat(storedHeight) : 48
        let storedSize = defaults.double(forKey: "iconSize")
        let fallbackIcon: CGFloat = storedSize > 0 ? CGFloat(storedSize) : 24
        barHeight = height
        iconSize = min(fallbackIcon, Self.maximumIconSize(for: height))
        if defaults.object(forKey: "showPinnedOnAllScreens") == nil {
            showPinnedOnAllScreens = true
        } else {
            showPinnedOnAllScreens = defaults.bool(forKey: "showPinnedOnAllScreens")
        }
        if defaults.object(forKey: "showFinder") == nil {
            showFinder = true
        } else {
            showFinder = defaults.bool(forKey: "showFinder")
        }
        if defaults.object(forKey: "showTrash") == nil {
            showTrash = true
        } else {
            showTrash = defaults.bool(forKey: "showTrash")
        }
        if defaults.object(forKey: "openWindowsOnClickedDisplay") == nil {
            openWindowsOnClickedDisplay = true
        } else {
            openWindowsOnClickedDisplay = defaults.bool(forKey: "openWindowsOnClickedDisplay")
        }
        ready = true
    }

    private func persist() {
        guard ready else { return }
        defaults.set(alignment.rawValue, forKey: "alignment")
        defaults.set(style.rawValue, forKey: "barStyle")
        defaults.set(Double(barHeight), forKey: "barHeight")
        defaults.set(Double(iconSize), forKey: "iconSize")
        defaults.set(showPinnedOnAllScreens, forKey: "showPinnedOnAllScreens")
        defaults.set(showFinder, forKey: "showFinder")
        defaults.set(showTrash, forKey: "showTrash")
        defaults.set(openWindowsOnClickedDisplay, forKey: "openWindowsOnClickedDisplay")
        onChange?()
    }
}
