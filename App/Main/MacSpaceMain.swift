import AppKit
import MacSpaceApp
import MacSpacePlatform
import SwiftUI

/// Closing the last window quits the app unless it keeps running (in the menu bar, or unseen in the background), where it goes on
/// with the modules' background tasks and automatic cleanup.
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
            alert.messageText = String(localized: "This copy of MacSpace is incomplete")
            alert.informativeText = String(localized: "Quit MacSpace and copy it again. Permissions given to this copy would be lost at the next update.")
            alert.alertStyle = .critical
            alert.addButton(withTitle: String(localized: "Quit"))
            alert.addButton(withTitle: String(localized: "Continue"))
            if alert.runModal() == .alertFirstButtonReturn { NSApp.terminate(nil) }
        }
        Task { @MainActor in await AppModel.host.start() }
        StatusItemController.shared.install(host: AppModel.host)
        AppNotifications.shared.install(host: AppModel.host)
        BackgroundPresence.shared.install()
        // Onboarding needs the window. SwiftUI leaves it closed when MacSpace is opened with arguments (`--onboarding`) or as a login
        // item, so it is opened here if it has not appeared by itself.
        if Onboarding.shared.isShowing {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                if AppRouter.mainWindow == nil { AppRouter.shared.open() }
            }
        }
    }

    /// Clicking the Dock icon with no window open opens it again.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { Task { @MainActor in AppRouter.shared.open() } }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !GeneralSettings.keepsRunning()
    }
}

@main
struct MacSpaceMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var host = AppModel.host
    @StateObject private var updates = UpdateController()

    var body: some Scene {
        // Only the window of the chosen kind opens at launch, and neither is restored: both opening, then one closing itself,
        // left an empty glass frame and its shadow on screen beside the standard window.
        Window("MacSpace", id: MacSpaceWindow.glass) {
            MainView(host: host, updates: updates)
        }
        .defaultLaunchBehavior(DesignSettings.shared.standardWindow ? .suppressed : .presented)
        .restorationBehavior(.disabled)
        // Opened by `macspace://main` when no window has been open yet (`AppRouter.open`).
        .handlesExternalEvents(matching: [MacSpaceWindow.glass])
        .windowStyle(.plain)
        .windowBackgroundDragBehavior(.enabled)
        // The glass's default size (`Theme.defaultSize`) and the invisible resize band around it (`Theme.resizeMargin`).
        .defaultSize(width: 716, height: 530)
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
        // SwiftUI lists every window scene in the Window menu, open or not: "MacSpace" twice and the Shader Studio even with the
        // design tools off. The two other scenes leave out their item; the first keeps it, with the app's default menus (on all
        // three, `commandsRemoved()` also took Quit and the Edit, Window and Help menus).
        .commandsRemoved()
        // MacSpace draws the window's buttons and its band (`StandardWindowView`); the content reaches the top of the window.
        .windowStyle(.hiddenTitleBar)
        .handlesExternalEvents(matching: [MacSpaceWindow.standard])
        .defaultLaunchBehavior(DesignSettings.shared.standardWindow ? .presented : .suppressed)
        .restorationBehavior(.disabled)
        .defaultSize(width: 900, height: 600)

        // Temporary: the Shader Studio (Design menu, ⌥⌘L), only reachable with the design tools on (`DesignTools`).
        Window("Shader Studio", id: ColorLabView.windowID) {
            ColorLabView()
        }
        .commandsRemoved()
        .defaultSize(width: 520, height: 820)
        .handlesExternalEvents(matching: [])
        // Over the main window, so it stays in view while parts are picked there.
        .windowLevel(.floating)
    }
}
