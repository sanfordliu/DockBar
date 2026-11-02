import AppKit
import Darwin
import Foundation

@MainActor
final class TrashService {
    static let shared = TrashService()

    private(set) var count = 0
    private(set) var automationDenied = false
    private(set) var finderSucceeded = false
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: Int32 = -1
    private var refreshTask: Task<Void, Never>?
    private var finderGeneration = 0

    private struct ScriptResult: Sendable {
        var value: Int32
        var errorCode: Int?
        var failed: Bool
    }

    private nonisolated static func runScript(_ source: String) async -> ScriptResult {
        await Task.detached(priority: .utility) {
            let script = NSAppleScript(source: source)
            var error: NSDictionary?
            let result = script?.executeAndReturnError(&error)
            if let error {
                let code = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue
                return ScriptResult(value: 0, errorCode: code, failed: true)
            }
            return ScriptResult(value: result?.int32Value ?? 0, errorCode: nil, failed: false)
        }.value
    }

    func start() {
        refreshLocal()
        watchTrashFolder()
        if UserDefaults.standard.bool(forKey: "finderAutomationOK") {
            refreshFromFinder()
        }
    }

    func refresh() {
        refreshFromFinder()
    }

    func open() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "\(NSHomeDirectory())/.Trash"))
    }

    func empty() {
        Task { @MainActor in
            let outcome = await Self.runScript("tell application \"Finder\" to empty trash")
            if outcome.failed {
                self.automationDenied = true
                Log.error("Empty Trash was not allowed")
            } else {
                self.automationDenied = false
                self.finderSucceeded = true
                UserDefaults.standard.set(true, forKey: "finderAutomationOK")
            }
            self.refreshLocal()
            TaskbarModel.shared.noteTrashCount(self.count)
            self.refreshFromFinder()
        }
    }

    enum DropAction: Equatable {
        case trash
        case eject
        case ignore
    }

    /// Files go to the Trash. Ejectable volumes are ejected. The startup disk is left alone.
    static func dropAction(isVolume: Bool, ejectable: Bool, removable: Bool, internalVolume: Bool) -> DropAction {
        guard isVolume else { return .trash }
        if internalVolume { return ejectable ? .eject : .ignore }
        return (ejectable || removable) ? .eject : .ignore
    }

    func receive(urls: [URL]) {
        for url in urls {
            switch action(for: url) {
            case .eject:
                do {
                    try NSWorkspace.shared.unmountAndEjectDevice(at: url)
                } catch {
                    Log.error("Could not eject volume: \(error.localizedDescription)", path: url.path)
                }
            case .trash:
                trash(urls: [url])
            case .ignore:
                Log.error("Left volume in place", path: url.path)
            }
        }
    }

    private func action(for url: URL) -> DropAction {
        let keys: Set<URLResourceKey> = [.isVolumeKey, .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsInternalKey]
        let values = try? url.resourceValues(forKeys: keys)
        return Self.dropAction(
            isVolume: values?.isVolume == true,
            ejectable: values?.volumeIsEjectable == true,
            removable: values?.volumeIsRemovable == true,
            internalVolume: values?.volumeIsInternal == true
        )
    }

    func trash(urls: [URL]) {
        for url in urls {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                Log.error("Could not trash item: \(error.localizedDescription)", path: url.path)
            }
        }
        scheduleRefresh()
    }

    private func watchTrashFolder() {
        let path = "\(NSHomeDirectory())/.Trash"
        descriptor = Darwin.open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .link],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.scheduleRefresh()
            }
        }
        source.resume()
        self.source = source
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self.refreshFromFinder()
        }
    }

    private func refreshFromFinder() {
        finderGeneration += 1
        let generation = finderGeneration
        Task { @MainActor in
            let outcome = await Self.runScript("tell application \"Finder\" to count items of trash")
            guard generation == self.finderGeneration else { return }
            if outcome.failed {
                if outcome.errorCode == -1743 { self.automationDenied = true }
                self.refreshLocal()
                return
            }
            self.automationDenied = false
            self.finderSucceeded = true
            UserDefaults.standard.set(true, forKey: "finderAutomationOK")
            self.count = Int(outcome.value)
            TaskbarModel.shared.noteTrashCount(self.count)
        }
    }

    private func refreshLocal() {
        let url = URL(fileURLWithPath: "\(NSHomeDirectory())/.Trash")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        count = names.filter { !$0.hasPrefix(".") }.count
        TaskbarModel.shared.noteTrashCount(count)
    }
}
