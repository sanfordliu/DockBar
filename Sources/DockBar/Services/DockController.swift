import Foundation

/// Hides the system Dock while DockBar is running and puts the previous setting back on quit.
@MainActor
enum DockController {
    private static let hidingKey = "dockBarIsHidingDock"
    private static let autohideKey = "savedDockAutohide"
    private static let hadDelayKey = "savedDockHadDelay"
    private static let delayKey = "savedDockAutohideDelay"

    /// Test hook. Production calls the real command. Tests replace this so nothing restarts the Dock.
    static var execute: @MainActor (String, [String]) -> String = runCommand

    static func runCommand(path: String, arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return ""
        }
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func hideNativeDock() {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: hidingKey) {
            let current = readDock("autohide")
            let delay = readDock("autohide-delay")
            defaults.set(current == "1", forKey: autohideKey)
            defaults.set(!delay.isEmpty, forKey: hadDelayKey)
            if let value = Double(delay) {
                defaults.set(value, forKey: delayKey)
            }
            defaults.set(true, forKey: hidingKey)
            flush()
        }
        enforceHidden()
    }

    static func restoreNativeDock() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: hidingKey) else { return }
        let autohide = defaults.bool(forKey: autohideKey)
        runDefaults(["write", "com.apple.dock", "autohide", "-bool", autohide ? "true" : "false"])
        if defaults.bool(forKey: hadDelayKey) {
            let delay = defaults.double(forKey: delayKey)
            runDefaults(["write", "com.apple.dock", "autohide-delay", "-float", String(delay)])
        } else {
            runDefaults(["delete", "com.apple.dock", "autohide-delay"])
        }
        defaults.set(false, forKey: hidingKey)
        flush()
        restartDock()
        Log.info("Restored the macOS Dock")
    }

    /// True when the Dock is visible or its autohide delay is not the value DockBar sets.
    nonisolated static func needsDockHide(autohide: String, delay: Double) -> Bool {
        !(autohide == "1" && abs(delay - 1000) < 0.5)
    }

    /// Re-hides the Dock if something else (such as Control-Option-D) shows it again.
    static func enforceHidden() {
        guard UserDefaults.standard.bool(forKey: hidingKey) else { return }
        let autohide = readDock("autohide")
        let delay = Double(readDock("autohide-delay")) ?? -1
        guard needsDockHide(autohide: autohide, delay: delay) else { return }
        runDefaults(["write", "com.apple.dock", "autohide", "-bool", "true"])
        runDefaults(["write", "com.apple.dock", "autohide-delay", "-float", "1000"])
        restartDock()
        Log.info("Hid the macOS Dock")
    }

    /// Reads Dock defaults off the main actor, then hides the Dock only when the values differ.
    static func enforceHiddenInBackground() {
        guard UserDefaults.standard.bool(forKey: hidingKey) else { return }
        Task.detached {
            let autohide = Self.readDockOffMain("autohide")
            let delay = Double(Self.readDockOffMain("autohide-delay")) ?? -1
            guard Self.needsDockHide(autohide: autohide, delay: delay) else { return }
            await MainActor.run {
                Self.enforceHidden()
            }
        }
    }

    private nonisolated static func readDockOffMain(_ key: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["read", "com.apple.dock", key]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return ""
        }
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func readDock(_ key: String) -> String {
        runDefaults(["read", "com.apple.dock", key])
    }

    @discardableResult
    private static func runDefaults(_ arguments: [String]) -> String {
        execute("/usr/bin/defaults", arguments)
    }

    private static func restartDock() {
        _ = execute("/usr/bin/killall", ["Dock"])
    }

    private static func flush() {
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
    }
}
