import SwiftUI

struct PermissionsOnboardingView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("DockBar replaces the Dock")
                .font(.title2.bold())
            Text("A glass bar sits at the bottom of every screen. It keeps your Dock shortcuts, shows the apps open on that screen, and previews their windows when you point at an icon. The Trash stays on the right.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 12) {
                row("Accessibility", "Required to switch, minimize, and close windows.") {
                    SettingsWindowController.shared.yieldToSystemUI()
                    Permissions.promptAccessibility()
                }
                row("Screen Recording", "Required for the window previews.") {
                    SettingsWindowController.shared.yieldToSystemUI()
                    if !Permissions.requestScreenCapture() {
                        Permissions.openPrivacyPane("Privacy_ScreenCapture")
                    }
                }
                row("Finder", "Required to empty the Trash. The icon still shows a local count without it.") {
                    SettingsWindowController.shared.yieldToSystemUI()
                    TrashService.shared.refresh()
                }
            }

            HStack {
                Button("Continue") {
                    UserDefaults.standard.set(true, forKey: "skippedAccessibilityOnboarding")
                    SettingsWindowController.shared.close()
                }
                Spacer()
                Button("Open Settings") {
                    SettingsWindowController.shared.showSettings()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func row(_ title: String, _ detail: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button("Allow", action: action)
        }
    }
}
