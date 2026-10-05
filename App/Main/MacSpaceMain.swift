import AppKit
import MacSpaceApp
import MacSpacePlatform
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
        // An app copied in by hand may be unknown to Launch Services, which makes the helper "not found" instead of "needs approval".
        if PrivilegedHelperInstaller.status == .notFound { PrivilegedHelperInstaller.registerAppWithLaunchServices() }
        // A copy with pieces missing (copied while it was being built) must not be given permissions: macOS would tie them to this
        // one build, and every update would lose them. Said once, plainly.
        if !CodeIntegrity.isIntact(Bundle.main.bundleURL) {
            let alert = NSAlert()
            alert.messageText = "This copy of MacSpace is incomplete"
            alert.informativeText = "Quit MacSpace and copy it again. Permissions given to this copy would be lost at the next update."
            alert.alertStyle = .critical
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Continue")
            if alert.runModal() == .alertFirstButtonReturn { NSApp.terminate(nil) }
        }
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
        // Only the window of the chosen kind opens at launch, and neither is restored: both opening, then one closing itself,
        // left an empty glass frame and its shadow on screen beside the standard window.
        Window("MacSpace", id: MacSpaceWindow.glass) {
            MainView(host: host, updates: updates)
        }
        .defaultLaunchBehavior(DesignSettings.shared.standardWindow ? .suppressed : .presented)
        .restorationBehavior(.disabled)
        .windowStyle(.plain)
        .windowBackgroundDragBehavior(.enabled)
        // The glass's default size (`Theme.defaultSize`) and the invisible resize band around it (`Theme.resizeMargin`).
        .defaultSize(width: 716, height: 506)
        .windowResizability(.contentMinSize)
        .commands {
            DesignCommands()
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updates.checkForUpdates() }.disabled(!updates.canCheck)
            }
        }

        // The same app in a standard macOS window with a sidebar (Settings > Design > Standard window with sidebar).
        Window("MacSpace", id: MacSpaceWindow.standard) {
            StandardWindowView(host: host, updates: updates)
        }
        // MacSpace draws the window's buttons and its band (`StandardWindowView`); the content reaches the top of the window.
        .windowStyle(.hiddenTitleBar)
        .defaultLaunchBehavior(DesignSettings.shared.standardWindow ? .presented : .suppressed)
        .restorationBehavior(.disabled)
        .defaultSize(width: 900, height: 600)

        // Temporary: the Color Lab (Design menu, ⌥⌘L).
        Window("Color Lab", id: ColorLabView.windowID) {
            ColorLabView()
        }
        .defaultSize(width: 480, height: 760)

        MenuBarExtra(isInserted: $showInMenuBar) {
            MenuBarContent(host: host)
        } label: {
            MenuBarIcon(host: host)
        }
    }
}
