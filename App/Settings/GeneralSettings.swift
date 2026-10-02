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
        FormBlock(title: "General") {
            FormToggleRow(title: "Show in the menu bar", help: "Keeps MacSpace running when you close the window, so background tasks keep working.",
                          isOn: $showInMenuBar)
            FormDivider()
            FormToggleRow(title: "Open at login", help: "Starts MacSpace when you log in.",
                          status: loginError.map { [($0, Color.red)] } ?? [],
                          isOn: Binding(get: { opensAtLogin }, set: setOpensAtLogin))
            FormDivider()
            if updates.isAvailable {
                FormToggleRow(title: "Check for updates automatically",
                              isOn: Binding(get: { updates.automaticallyChecks }, set: { updates.automaticallyChecks = $0 }))
                FormDivider()
                FormRow {
                    Text("Updates")
                    Spacer()
                    ActionPill(title: "Check Now", enabled: updates.canCheck) { updates.checkForUpdates() }
                }
            } else {
                FormRow {
                    Text("Updates")
                    Spacer()
                    Text("Not in this build").foregroundStyle(.secondary)
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
