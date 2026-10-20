import AppKit
import Foundation
import MacSpaceSdk

/// The app's side of `ModuleServices` for one module: its notifications carry its id, so a click opens its page, and its System
/// Settings panes open through the same check as `Action.openSettings`.
struct AppModuleServices: ModuleServices {
    let module: String
    let openPane: @Sendable (URL) -> Void

    func notify(title: String, body: String) { AppNotifications.post(module: module, title: title, body: body) }

    func openSettings(_ url: URL) {
        guard Action.isSettingsPane(url) else { return }
        openPane(url)
    }
}

public enum SettingsPane {
    /// Opens the pane in System Settings, from any thread. Only with URLs that `Action.isSettingsPane` let through.
    @Sendable public static func open(_ url: URL) { NSWorkspace.shared.open(url) }
}
