import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        SettingsForm(settings: TaskbarModel.shared.settings)
    }
}

private struct SettingsForm: View {
    @Bindable var settings: BarSettings
    @State private var loginError: String?

    var body: some View {
        ScrollView {
            Form {
                Section("Appearance") {
                    Picker("Icons", selection: $settings.alignment) {
                        ForEach(IconAlignment.allCases) { alignment in
                            Text(alignment.label).tag(alignment)
                        }
                    }
                    Picker("Bar", selection: $settings.style) {
                        ForEach(BarStyle.allCases) { style in
                            Text(style.label).tag(style)
                        }
                    }
                    LabeledContent("Bar height") {
                        Text("\(Int(settings.barHeight)) pt")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $settings.barHeight, in: 40...72, step: 2) {
                        Text("Bar height")
                    }
                    LabeledContent("Icon size") {
                        Text("\(Int(settings.iconSize)) pt")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $settings.iconSize, in: 16...BarSettings.maximumIconSize(for: settings.barHeight), step: 2) {
                        Text("Icon size")
                    }
                    Toggle("Show pinned apps on every screen", isOn: $settings.showPinnedOnAllScreens)
                    Toggle("Show Finder as the first icon", isOn: $settings.showFinder)
                    Toggle("Show Trash", isOn: $settings.showTrash)
                }

                Section("Permissions") {
                    PermissionRows()
                }

                Section("Startup") {
                    Toggle("Launch DockBar at login", isOn: launchBinding)
                    if SMAppService.mainApp.status == .requiresApproval {
                        Text("macOS is waiting for you to allow DockBar in System Settings → General → Login Items.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let loginError {
                        Text(loginError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section("macOS Dock") {
                    Text("DockBar hides the Dock while it is running. Quitting puts your previous Dock setting back.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Quit and Restore the macOS Dock") {
                        NSApp.terminate(nil)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 560, height: 640)
    }

    private var launchBinding: Binding<Bool> {
        Binding(
            get: { SMAppService.mainApp.status == .enabled },
            set: { enabled in
                do {
                    if enabled {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                    loginError = nil
                } catch {
                    loginError = error.localizedDescription
                }
            }
        )
    }
}

private struct PermissionRows: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(alignment: .leading, spacing: 10) {
                permissionRow(
                    name: "Accessibility",
                    detail: "Focus, minimize, and close windows.",
                    granted: Permissions.isAccessibilityTrusted,
                    actionTitle: "Grant",
                    action: {
                        SettingsWindowController.shared.yieldToSystemUI()
                        Permissions.promptAccessibility()
                    }
                )
                permissionRow(
                    name: "Screen Recording",
                    detail: "Show window previews.",
                    granted: Permissions.isScreenCaptureGranted,
                    actionTitle: "Grant",
                    action: {
                        SettingsWindowController.shared.yieldToSystemUI()
                        if !Permissions.requestScreenCapture() {
                            Permissions.openPrivacyPane("Privacy_ScreenCapture")
                        }
                    }
                )
                permissionRow(
                    name: "Finder Automation",
                    detail: "See whether the Trash is full and empty it.",
                    granted: TrashService.shared.finderSucceeded,
                    actionTitle: "Ask Finder",
                    action: {
                        SettingsWindowController.shared.yieldToSystemUI()
                        TrashService.shared.refresh()
                    }
                )
            }
            .padding(.vertical, 4)
        }
    }

    private func permissionRow(
        name: String,
        detail: String,
        granted: Bool,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button(actionTitle, action: action)
            }
        }
    }
}
