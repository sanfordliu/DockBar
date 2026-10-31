import Darwin
import Foundation

/// Names the browser profile that owns a window, so a preview can tell work from personal.
/// Chromium browsers share `--profile-directory` and a Local State file. Firefox uses profiles.ini.
enum BrowserProfile {
    @MainActor
    static func stamp(_ windows: [WindowInfo], apps: [pid_t: LiveApp]) -> [WindowInfo] {
        let live = Set(windows.map(\.ownerPID))
        cache = cache.filter { live.contains($0.key) }
        return windows.map { window in
            var copy = window
            copy.profileName = name(bundleID: apps[window.ownerPID]?.bundleID, pid: window.ownerPID)
            return copy
        }
    }

    @MainActor
    static func name(bundleID: String?, pid: pid_t) -> String? {
        if let cached = cache[pid] { return cached }
        guard let bundleID, let folder = supportFolder(bundleID: bundleID) else { return nil }
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        guard let arguments = ProcessArguments.arguments(of: pid) else { return nil }
        let resolved = name(
            bundleID: bundleID,
            arguments: arguments,
            supportRoot: root.appendingPathComponent(folder, isDirectory: true)
        )
        if let resolved { cache[pid] = resolved }
        return resolved
    }

    /// Resolves a profile label from already-loaded arguments and the browser's support directory.
    static func name(bundleID: String?, arguments: [String], supportRoot: URL) -> String? {
        guard let bundleID else { return nil }
        if isFirefox(bundleID) {
            let ini = supportRoot.appendingPathComponent("profiles.ini")
            guard let text = try? String(contentsOf: ini, encoding: .utf8) else { return nil }
            return firefoxName(arguments: arguments, profilesIni: text)
        }
        guard supportFolder(bundleID: bundleID) != nil else { return nil }
        guard let state = localStateData(in: supportRoot) else { return nil }
        let names = profileNames(in: state)
        guard names.count > 1 else { return nil }
        let directory = profileDirectory(from: arguments) ?? "Default"
        return names[directory]
    }

    static func supportFolder(bundleID: String) -> String? {
        switch bundleID {
        case "com.google.Chrome": "Google/Chrome"
        case "com.google.Chrome.beta": "Google/Chrome Beta"
        case "com.google.Chrome.canary": "Google/Chrome Canary"
        case "com.google.Chrome.dev": "Google/Chrome Dev"
        case "org.chromium.Chromium": "Chromium"
        case "com.microsoft.edgemac": "Microsoft Edge"
        case "com.microsoft.edgemac.Beta": "Microsoft Edge Beta"
        case "com.microsoft.edgemac.Dev": "Microsoft Edge Dev"
        case "com.microsoft.edgemac.Canary": "Microsoft Edge Canary"
        case "com.brave.Browser": "BraveSoftware/Brave-Browser"
        case "com.brave.Browser.beta": "BraveSoftware/Brave-Browser-Beta"
        case "com.brave.Browser.nightly": "BraveSoftware/Brave-Browser-Nightly"
        case "com.vivaldi.Vivaldi": "Vivaldi"
        case "com.operasoftware.Opera": "com.operasoftware.Opera"
        case "company.thebrowser.Browser": "Arc"
        case "org.mozilla.firefox": "Firefox"
        case "org.mozilla.firefoxdeveloperedition": "Firefox Developer Edition"
        case "org.mozilla.nightly": "Firefox Nightly"
        default: nil
        }
    }

    static func profileDirectory(from arguments: [String]) -> String? {
        for (index, argument) in arguments.enumerated() {
            let flag = "--profile-directory"
            if argument == flag, index + 1 < arguments.count {
                return arguments[index + 1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
            if argument.hasPrefix(flag + "=") {
                return String(argument.dropFirst(flag.count + 1)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return nil
    }

    static func profileNames(in localState: Data) -> [String: String] {
        guard
            let root = try? JSONSerialization.jsonObject(with: localState) as? [String: Any],
            let profile = root["profile"] as? [String: Any],
            let cache = profile["info_cache"] as? [String: Any]
        else { return [:] }
        var names: [String: String] = [:]
        for (directory, value) in cache {
            guard let info = value as? [String: Any] else { continue }
            if let label = displayName(
                name: info["name"] as? String,
                userName: info["user_name"] as? String,
                gaiaName: info["gaia_name"] as? String
            ) {
                names[directory] = label
            }
        }
        return names
    }

    static func displayName(name: String?, userName: String?, gaiaName: String?) -> String? {
        let generic: Set<String> = ["Person 1", "Your Chrome", "Your Chromium"]
        if let name, !name.isEmpty, !generic.contains(name) { return name }
        if let gaiaName, !gaiaName.isEmpty { return gaiaName }
        if let userName, !userName.isEmpty { return userName }
        if let name, !name.isEmpty { return name }
        return nil
    }

    static func firefoxName(arguments: [String], profilesIni: String) -> String? {
        let profiles = firefoxProfiles(in: profilesIni)
        guard profiles.count > 1 else { return nil }
        if let selected = firefoxSelectedProfile(arguments) {
            return selected
        }
        if let path = argumentValue(arguments, flag: "-profile") ?? argumentValue(arguments, flag: "--profile") {
            let leaf = URL(fileURLWithPath: path).lastPathComponent
            return profiles.first { $0.path == path || $0.path.hasSuffix("/" + leaf) || $0.path == leaf }?.name
        }
        return profiles.first { $0.isDefault }?.name
    }

    struct FirefoxProfile: Equatable {
        var name: String
        var path: String
        var isDefault: Bool
    }

    static func firefoxProfiles(in text: String) -> [FirefoxProfile] {
        var profiles: [FirefoxProfile] = []
        var name: String?
        var path: String?
        var isDefault = false
        func flush() {
            if let name, let path {
                profiles.append(FirefoxProfile(name: name, path: path, isDefault: isDefault))
            }
            name = nil
            path = nil
            isDefault = false
        }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                flush()
                continue
            }
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "Name": name = parts[1]
            case "Path": path = parts[1]
            case "Default": isDefault = parts[1] == "1"
            default: break
            }
        }
        flush()
        return profiles
    }

    static func pageTitle(_ title: String, appName: String, profile: String?) -> String {
        var text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return appName }
        let productSuffixes = [
            " - \(appName)",
            " - Google Chrome",
            " - Microsoft Edge",
            " - Brave",
            " - Vivaldi",
            " - Opera",
            " - Chromium",
            " - Firefox",
            " - Arc",
        ]
        for suffix in productSuffixes where text.hasSuffix(suffix) {
            text = String(text.dropLast(suffix.count))
            break
        }
        if let profile {
            let suffix = " - \(profile)"
            if text.hasSuffix(suffix) {
                text = String(text.dropLast(suffix.count))
            }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? appName : trimmed
    }

    @MainActor private static var cache: [pid_t: String] = [:]

    private static func isFirefox(_ bundleID: String) -> Bool {
        bundleID == "org.mozilla.firefox"
            || bundleID == "org.mozilla.firefoxdeveloperedition"
            || bundleID == "org.mozilla.nightly"
    }

    private static func localStateData(in directory: URL) -> Data? {
        let candidates = [
            directory.appendingPathComponent("Local State"),
            directory.appendingPathComponent("User Data/Local State"),
        ]
        for url in candidates {
            if let data = try? Data(contentsOf: url), !data.isEmpty { return data }
        }
        return nil
    }

    private static func firefoxSelectedProfile(_ arguments: [String]) -> String? {
        for (index, argument) in arguments.enumerated() {
            if argument == "-P", index + 1 < arguments.count { return arguments[index + 1] }
            if argument.hasPrefix("-P"), !argument.hasPrefix("-profile"), argument.count > 2 {
                return String(argument.dropFirst(2))
            }
        }
        return nil
    }

    private static func argumentValue(_ arguments: [String], flag: String) -> String? {
        for (index, argument) in arguments.enumerated() {
            if argument == flag, index + 1 < arguments.count { return arguments[index + 1] }
            let prefixed = flag + "="
            if argument.hasPrefix(prefixed) {
                return String(argument.dropFirst(prefixed.count))
            }
        }
        return nil
    }
}

enum ProcessArguments {
    /// `nil` when the process arguments cannot be read. An empty array means they were read and there were none.
    static func arguments(of pid: pid_t) -> [String]? {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = Data(count: size)
        let copied = buffer.withUnsafeMutableBytes { raw -> Int32 in
            guard let base = raw.baseAddress else { return -1 }
            return sysctl(&mib, 3, base, &size, nil, 0)
        }
        guard copied == 0 else { return nil }
        return parse(buffer.prefix(size))
    }

    /// KERN_PROCARGS2: argc, executable path, padding NULLs, then argc argument strings.
    static func parse(_ data: Data) -> [String] {
        guard data.count >= MemoryLayout<Int32>.size else { return [] }
        let argc = data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc < 512 else { return [] }
        var index = MemoryLayout<Int32>.size
        func cString() -> String? {
            guard index < data.count else { return nil }
            let start = index
            while index < data.count, data[index] != 0 { index += 1 }
            let bytes = data.subdata(in: start..<index)
            if index < data.count { index += 1 }
            if bytes.isEmpty { return "" }
            return String(data: bytes, encoding: .utf8)
        }
        _ = cString()
        while index < data.count, data[index] == 0 { index += 1 }
        var arguments: [String] = []
        for _ in 0..<argc {
            guard let value = cString(), !value.isEmpty else { break }
            arguments.append(value)
        }
        return arguments
    }
}
