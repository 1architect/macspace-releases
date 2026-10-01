import AppKit
import MacSpaceApp
import SwiftUI

/// Closing the last window quits the app unless it lives in the menu bar, where it keeps running modules' background tasks.
@MainActor
enum AppModel {
    static let host = ModuleHost()
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Modules load as soon as the app starts, not when the window first appears: the window can open behind other apps or not at all
    /// (menu bar only), and nothing should wait for a click.
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in await AppModel.host.start() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !GeneralSettings.showsInMenuBar()
    }
}

@main
struct MacSpaceMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var host = AppModel.host
    @StateObject private var updates = UpdateController()
    @AppStorage(GeneralSettings.showInMenuBarKey) private var showInMenuBar = true

    var body: some Scene {
        Window("MACSPACE", id: "main") {
            MainView(host: host, updates: updates)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updates.checkForUpdates() }.disabled(!updates.canCheck)
            }
        }

        MenuBarExtra("MACSPACE", systemImage: "checkmark.shield", isInserted: $showInMenuBar) {
            MenuBarContent(host: host)
        }
    }
}
