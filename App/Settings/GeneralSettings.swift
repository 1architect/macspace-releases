import MacSpacePlatform
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
    @ObservedObject var host: ModuleHost
    @ObservedObject var updates: UpdateController
    @ObservedObject private var design = DesignSettings.shared
    @AppStorage(GeneralSettings.showInMenuBarKey) private var showInMenuBar = true
    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Section("General") {
            Picker("Theme", selection: Binding(get: { design.theme }, set: { design.theme = $0 })) {
                ForEach(PaletteScheme.themes) { Text($0.themeTitle).tag($0) }
            }
            Picker("Appearance", selection: $design.appearanceMode) {
                ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
            }
            .help("Night draws the theme on deep grounds, Day on light ones; Follow System switches with macOS.")
            SettingsLinkRow(title: "Permissions", note: permissionsNote) { host.settingsPage = .permissions }
            Toggle("Show in the menu bar", isOn: $showInMenuBar)
                .help("Keeps MacSpace running when you close the window, so background tasks keep working.")
            Toggle(isOn: Binding(get: { opensAtLogin }, set: setOpensAtLogin)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open at login")
                    if let loginError { Text(loginError).font(.caption).foregroundStyle(DesignSettings.shared.design.action) }
                }
            }
            .help("Starts MacSpace when you log in.")
            // The release the Mac runs, for reports and debugging: selectable, so it can be copied.
            LabeledContent("macOS") {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(MacOSRelease.current.description).textSelection(.enabled).monospacedDigit()
                    if !SupportedReleases.isSupported() {
                        Text("MacSpace has not been tested on this release yet.").font(.caption).foregroundStyle(DesignSettings.shared.design.action)
                    }
                }
            }
            .help("The macOS version and build MacSpace is running on.")
            if updates.isAvailable {
                Toggle("Check for updates automatically", isOn: Binding(get: { updates.automaticallyChecks }, set: { updates.automaticallyChecks = $0 }))
                HStack {
                    Text("Updates")
                    Spacer()
                    Button("Check Now") { updates.checkForUpdates() }.disabled(!updates.canCheck)
                }
            } else {
                LabeledContent("Updates") { Text("Not in this build").foregroundStyle(.secondary) }
            }
        }
    }

    /// How many permissions the active modules still need, or that all are given.
    private var permissionsNote: String? {
        let missing = PermissionsPage.permissions(host).filter { host.permissions.status(of: $0.permission) == .missing && $0.permission != .configurationProfile }.count
        return missing == 0 ? nil : (missing == 1 ? "1 needed" : "\(missing) needed")
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
