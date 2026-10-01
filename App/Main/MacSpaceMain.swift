import AppKit
import MacSpaceApp
import SwiftUI

/// Closing the last window quits the app unless it lives in the menu bar, where it keeps running modules' background tasks.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !GeneralSettings.showsInMenuBar()
    }
}

@main
struct MacSpaceMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var host = ModuleHost()
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
