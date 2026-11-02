import Darwin
import Foundation

/// Names the browser profile that owns a window, so a preview can tell work from personal.
/// Chromium browsers share `--profile-directory` and a Local State file. Firefox uses profiles.ini.
enum BrowserProfile {
    private final class Store: @unchecked Sendable {
        let lock = NSLock()
        var arguments: [pid_t: [String]] = [:]
        var files: [String: FileEntry] = [:]
        var chromium: [String: ChromiumEntry] = [:]
        var firefox: [String: FirefoxEntry] = [:]
    }

    private struct FileEntry {
        var modified: Date?
        var size: Int
        var data: Data?
    }

    private struct ChromiumEntry {
        var data: Data
        var names: [String: String]
        var tokens: [String: String]
    }

    private struct FirefoxEntry {
        var data: Data
        var text: String
    }

    private static let store = Store()

    @MainActor
    static func stamp(_ windows: [WindowInfo], apps: [pid_t: LiveApp]) -> [WindowInfo] {
        var argumentsForPID: [pid_t: [String]] = [:]
        func arguments(for pid: pid_t) -> [String] {
            if let cached = argumentsForPID[pid] { return cached }
            let loaded = cachedArguments(pid)
            argumentsForPID[pid] = loaded
            return loaded
        }
        let stamped = windows.map { window -> WindowInfo in
            var copy = window
            let app = apps[window.ownerPID]
            guard let bundleID = app?.bundleID, let root = supportRoot(bundleID: bundleID) else { return copy }
            copy.profileName = name(
                bundleID: bundleID,
                arguments: arguments(for: window.ownerPID),
                supportRoot: root,
                windowTitle: window.title,
                appName: app?.name
            )
            return copy
        }
        let seen = Set(windows.map(\.ownerPID))
        store.lock.lock()
        store.arguments = store.arguments.filter { seen.contains($0.key) }
        store.lock.unlock()
        return stamped
    }

    private static func supportRoot(bundleID: String) -> URL? {
        guard let folder = supportFolder(bundleID: bundleID) else { return nil }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(folder, isDirectory: true)
    }

    private static func cachedArguments(_ pid: pid_t) -> [String] {
        store.lock.lock()
        if let cached = store.arguments[pid] {
            store.lock.unlock()
            return cached
        }
        store.lock.unlock()
        let arguments = ProcessArguments.arguments(of: pid) ?? []
        store.lock.lock()
        store.arguments[pid] = arguments
        store.lock.unlock()
        return arguments
    }

    /// Chrome often hosts every profile in one process, so the process arguments are not enough.
    /// The window title carries the profile, as in "Inbox - Google Chrome - Ada (Work)".
    @MainActor
    static func name(bundleID: String?, pid: pid_t, title: String, appName: String?) -> String? {
        guard let bundleID, let folder = supportFolder(bundleID: bundleID) else { return nil }
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let arguments = cachedArguments(pid)
        return name(
            bundleID: bundleID,
            arguments: arguments,
            supportRoot: root.appendingPathComponent(folder, isDirectory: true),
            windowTitle: title,
            appName: appName
        )
    }

    /// Resolves a profile label from already-loaded arguments and the browser's support directory.
    static func name(
        bundleID: String?,
        arguments: [String],
        supportRoot: URL,
        windowTitle: String = "",
        appName: String? = nil
    ) -> String? {
        guard let bundleID else { return nil }
        if isFirefox(bundleID) {
            let ini = supportRoot.appendingPathComponent("profiles.ini")
            guard let text = cachedFirefoxIni(at: ini) else { return nil }
            return firefoxName(arguments: arguments, profilesIni: text)
        }
        guard supportFolder(bundleID: bundleID) != nil else { return nil }
        guard let profiles = cachedChromiumProfiles(in: supportRoot) else { return nil }
        guard profiles.names.count > 1 else { return nil }
        if let directory = profileDirectory(from: arguments) {
            return profiles.names[directory]
        }
        return profileLabel(
            in: windowTitle,
            tokens: profiles.tokens,
            products: products(bundleID: bundleID, appName: appName)
        )
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
        if let gaiaName, !gaiaName.isEmpty, !gaiaName.contains("@") { return gaiaName }
        if let name, !name.isEmpty { return name }
        if let userName, !userName.isEmpty, !userName.contains("@") { return userName }
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
        for product in products(bundleID: "", appName: appName) {
            let marker = " - \(product)"
            guard let range = text.range(of: marker, options: .backwards) else { continue }
            let head = text[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !head.isEmpty else { continue }
            text = String(head)
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

    /// Maps a title fragment such as "Work" or "Ada (Work)" to the label shown in the preview.
    static func profileLabel(in title: String, tokens: [String: String], products: [String]) -> String? {
        let ordered = tokens.keys.sorted { $0.count > $1.count }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        for product in products {
            let marker = " - \(product)"
            guard let range = trimmed.range(of: marker, options: .backwards) else { continue }
            var tail = trimmed[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if tail.hasPrefix("-") {
                tail = tail.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !tail.isEmpty else { continue }
            for token in ordered {
                let wrapped = "(\(token))"
                if tail == token || tail.hasSuffix(wrapped), let label = tokens[token], !label.isEmpty {
                    return label
                }
            }
        }
        return nil
    }

    static func titleTokens(in localState: Data) -> [String: String] {
        guard
            let root = try? JSONSerialization.jsonObject(with: localState) as? [String: Any],
            let profile = root["profile"] as? [String: Any],
            let cache = profile["info_cache"] as? [String: Any]
        else { return [:] }
        var tokens: [String: String] = [:]
        for (_, value) in cache {
            guard let info = value as? [String: Any] else { continue }
            let raw = (info["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let label = displayName(
                name: info["name"] as? String,
                userName: info["user_name"] as? String,
                gaiaName: info["gaia_name"] as? String
            ) else { continue }
            if !raw.isEmpty { tokens[raw] = label }
            tokens[label] = label
        }
        return tokens
    }

    static func products(bundleID: String, appName: String?) -> [String] {
        var names: [String] = []
        func add(_ name: String) {
            guard !name.isEmpty, !names.contains(name) else { return }
            names.append(name)
        }
        if let appName { add(appName) }
        switch bundleID {
        case "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "com.google.Chrome.dev":
            add("Google Chrome")
        case "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev", "com.microsoft.edgemac.Canary":
            add("Microsoft Edge")
        case "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly":
            add("Brave")
        case "com.vivaldi.Vivaldi": add("Vivaldi")
        case "com.operasoftware.Opera": add("Opera")
        case "org.chromium.Chromium": add("Chromium")
        case "company.thebrowser.Browser": add("Arc")
        case "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly":
            add("Firefox")
        default:
            break
        }
        for fallback in ["Google Chrome", "Microsoft Edge", "Brave", "Vivaldi", "Opera", "Chromium", "Firefox", "Arc"] {
            add(fallback)
        }
        return names
    }

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
            if let data = cachedData(at: url), !data.isEmpty { return data }
        }
        return nil
    }

    private static func cachedChromiumProfiles(in directory: URL) -> (names: [String: String], tokens: [String: String])? {
        guard let data = localStateData(in: directory) else { return nil }
        let key = directory.path
        store.lock.lock()
        if let cached = store.chromium[key], cached.data == data {
            let names = cached.names
            let tokens = cached.tokens
            store.lock.unlock()
            return (names, tokens)
        }
        store.lock.unlock()
        let names = profileNames(in: data)
        let tokens = titleTokens(in: data)
        store.lock.lock()
        store.chromium[key] = ChromiumEntry(data: data, names: names, tokens: tokens)
        store.lock.unlock()
        return (names, tokens)
    }

    private static func cachedFirefoxIni(at url: URL) -> String? {
        guard let data = cachedData(at: url), !data.isEmpty else { return nil }
        let key = url.path
        store.lock.lock()
        if let cached = store.firefox[key], cached.data == data {
            let text = cached.text
            store.lock.unlock()
            return text
        }
        store.lock.unlock()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        store.lock.lock()
        store.firefox[key] = FirefoxEntry(data: data, text: text)
        store.lock.unlock()
        return text
    }

    private static func cachedData(at url: URL) -> Data? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let modified = values?.contentModificationDate
        let size = values?.fileSize ?? -1
        let key = url.path
        store.lock.lock()
        if let entry = store.files[key], entry.modified == modified, entry.size == size {
            let data = entry.data
            store.lock.unlock()
            return data
        }
        store.lock.unlock()
        let data = try? Data(contentsOf: url)
        store.lock.lock()
        store.files[key] = FileEntry(modified: modified, size: size, data: data)
        store.lock.unlock()
        return data
    }

    private static let firefoxAttachedFlags: Set<String> = ["-ProfileManager"]

    private static func firefoxSelectedProfile(_ arguments: [String]) -> String? {
        for (index, argument) in arguments.enumerated() {
            if argument == "-P" {
                guard index + 1 < arguments.count else { return nil }
                let name = arguments[index + 1]
                guard !name.hasPrefix("-") else { return nil }
                return name
            }
            if argument.hasPrefix("-P"),
               !argument.hasPrefix("-profile"),
               argument.count > 2,
               !firefoxAttachedFlags.contains(argument) {
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
