import MacSpacePlatform
import ServiceManagement
import SwiftUI

/// App-wide choices: what happens when the window closes (MacSpace quits, or keeps running in the menu bar or unseen in the
/// background, which lets modules keep watching and cleaning) and whether it opens at login.
public enum GeneralSettings {
    /// What closing the last window does.
    public enum ClosedWindow: String, CaseIterable, Identifiable, Sendable {
        /// MacSpace quits.
        case quit
        /// MacSpace keeps running, with its item in the menu bar.
        case menuBar
        /// MacSpace keeps running with no menu bar item and no Dock icon; opening it again (Applications, Spotlight, a notification)
        /// shows the window.
        case background

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .quit: return "Quit MacSpace"
            case .menuBar: return "Keep running in the menu bar"
            case .background: return "Keep running in the background"
            }
        }
    }

    public static let closedWindowKey = "closedWindow"
    /// The switch the choice replaced: on kept MacSpace in the menu bar, off quit it.
    public static let showInMenuBarKey = "showInMenuBar"

    public static func closedWindow(_ defaults: UserDefaults = .standard) -> ClosedWindow {
        if let raw = defaults.string(forKey: closedWindowKey), let choice = ClosedWindow(rawValue: raw) { return choice }
        return defaults.object(forKey: showInMenuBarKey) as? Bool ?? true ? .menuBar : .quit
    }

    public static func setClosedWindow(_ choice: ClosedWindow, _ defaults: UserDefaults = .standard) {
        defaults.set(choice.rawValue, forKey: closedWindowKey)
    }

    public static func showsInMenuBar(_ defaults: UserDefaults = .standard) -> Bool {
        closedWindow(defaults) == .menuBar
    }

    /// Whether MacSpace goes on running once its last window closes.
    public static func keepsRunning(_ defaults: UserDefaults = .standard) -> Bool {
        closedWindow(defaults) != .quit
    }
}

struct GeneralSettingsSection: View {
    @ObservedObject var host: ModuleHost
    @ObservedObject var updates: UpdateController
    @ObservedObject private var design = DesignSettings.shared
    @State private var closedWindow = GeneralSettings.closedWindow()
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
            SettingsLinkRow(title: "Permissions", note: permissionsNote) { host.settingsPage = .permissions }
            Picker(selection: Binding(get: { closedWindow }, set: { closedWindow = $0; GeneralSettings.setClosedWindow($0) })) {
                ForEach(GeneralSettings.ClosedWindow.allCases) { Text($0.title).tag($0) }
            } label: {
                InfoTitle(title: "When the window closes", info: "In the background, MacSpace has no menu bar or Dock icon. Open it again from Applications.")
            }
            Toggle(isOn: Binding(get: { opensAtLogin }, set: setOpensAtLogin)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open at login")
                    if let loginError { Text(loginError).font(.caption).foregroundStyle(DesignSettings.shared.design.action) }
                }
            }
            // The release the Mac runs, for reports and debugging: selectable, so it can be copied.
            LabeledContent("macOS") {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(MacOSRelease.current.description).textSelection(.enabled).monospacedDigit()
                    if !SupportedReleases.isSupported() {
                        Text("MacSpace has not been tested on this release yet.").font(.caption).foregroundStyle(DesignSettings.shared.design.action)
                    }
                }
            }
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

/// Which of MacSpace's notifications show in Notification Center (`AppNotifications`). The modules' own are under each module.
struct NotificationSettingsSection: View {
    @State private var tick = 0

    var body: some View {
        let _ = tick
        let notifications = AppNotifications.shared
        Section("Notifications") {
            ForEach(AppNotifications.Kind.allCases) { kind in
                Toggle(kind.title, isOn: Binding(get: { notifications.isOn(kind) }, set: { notifications.set(kind, on: $0); tick += 1 }))
            }
        }
    }
}
