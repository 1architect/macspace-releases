import ServiceManagement
import SwiftUI

/// App-wide choices: whether MacSpace lives in the menu bar and opens at login, which lets modules keep watching with the window closed.
public enum GeneralSettings {
    public static let showInMenuBarKey = "showInMenuBar"

    public static func showsInMenuBar(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: showInMenuBarKey) as? Bool ?? true
    }
}

struct GeneralSettingsSection: View {
    @ObservedObject var updates: UpdateController
    @AppStorage(GeneralSettings.showInMenuBarKey) private var showInMenuBar = true
    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Section("General") {
            Toggle(isOn: $showInMenuBar) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show in the menu bar")
                    Text("Keeps MacSpace running when you close the window, so background tasks keep working.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if updates.isAvailable {
                Toggle("Check for updates automatically", isOn: Binding(get: { updates.automaticallyChecks }, set: { updates.automaticallyChecks = $0 }))
                Button("Check for Updates Now") { updates.checkForUpdates() }.disabled(!updates.canCheck)
            } else {
                Text("Updates are not available in this build.").font(.caption).foregroundStyle(.secondary)
            }
            Toggle(isOn: Binding(get: { opensAtLogin }, set: setOpensAtLogin)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open at login")
                    if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                    else { Text("Starts MacSpace when you log in.").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }

    private func setOpensAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        opensAtLogin = SMAppService.mainApp.status == .enabled
    }
}
