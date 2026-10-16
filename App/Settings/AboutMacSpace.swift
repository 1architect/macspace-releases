import AppKit
import MacSpacePlatform
import MacSpaceSdk
import ServiceManagement
import SwiftUI

/// The application menu's About command, matching MacBat's native alert layout.
@MainActor
public enum AboutMacSpace {
    private static var uninstalling = false

    static func makeAlert(bundle: Bundle = .main) -> AppAlert {
        let alert = AppAlert()
        alert.icon = NSApp.applicationIconImage
        alert.messageText = "MacSpace"
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        alert.informativeText = [String(format: String(localized: "Version %@"), version), "",
                                 String(format: String(localized: "Developed by\n%@"), "Gio Mantovani/1architect")].joined(separator: "\n")
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Uninstall…")).hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "GitHub"))
        return alert
    }

    public static func show(host: ModuleHost) {
        guard !uninstalling else { return }
        switch makeAlert().runModal() {
        case .alertSecondButtonReturn: confirmUninstall(host: host)
        case .alertThirdButtonReturn: NSWorkspace.shared.open(URL(string: "https://github.com/1architect/macspace-releases")!)
        default: break
        }
    }

    private static func confirmUninstall(host: ModuleHost) {
        let alert = AppAlert()
        alert.messageText = String(localized: "Uninstall MacSpace?")
        alert.informativeText = String(localized: "Restores settings changed by MacSpace and moves the app to the Trash. Your history is kept. Freed files cannot be restored.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Uninstall")).hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        uninstalling = true
        Task {
            defer { uninstalling = false }
            do { try await AppUninstaller.uninstall(host: host) }
            catch {
                let failure = AppAlert()
                failure.messageText = String(localized: "Couldn’t uninstall MacSpace")
                failure.informativeText = error.localizedDescription
                failure.addButton(withTitle: String(localized: "OK"))
                failure.runModal()
            }
        }
    }
}

/// An ordered pipeline: a failed restoration must prevent removal of the helper or app.
@MainActor
enum AppUninstaller {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func run(_ steps: [@MainActor () async throws -> Void]) async throws {
        for step in steps { try await step() }
    }

    static func uninstall(host: ModuleHost) async throws {
        let app = Bundle.main.bundleURL.resolvingSymlinksInPath()
        guard app.pathExtension == "app" else { throw Failure(message: String(localized: "Move MacSpace to the Trash from Applications.")) }
        guard !host.isCleaning, !host.autoCleaner.isRunning, !host.handles.contains(where: \.isBusy) else {
            throw Failure(message: String(localized: "Wait for the current task to finish, then try again."))
        }
        for handle in host.handles { handle.beginUninstall() }
        await host.scheduler.stopAndWait()
        await host.autoCleaner.stopAndWait()
        for handle in host.handles { handle.setWatched(false) }
        do {
            try await run([
                {
                    // Include disabled modules: disabling a module does not undo its changes.
                    for handle in host.handles {
                        let result = await handle.prepareForUninstall()
                        guard result.outcome == .succeeded else {
                            throw Failure(message: ([handle.manifest.name + ": " + result.message] + result.details).joined(separator: "\n"))
                        }
                    }
                },
                {
                    if SMAppService.mainApp.status == .enabled { try await SMAppService.mainApp.unregister() }
                    if PrivilegedHelperInstaller.status != .notRegistered && PrivilegedHelperInstaller.status != .notFound {
                        try await PrivilegedHelperInstaller.unregister()
                    }
                },
                {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        NSWorkspace.shared.recycle([app]) { _, error in
                            if let error { continuation.resume(throwing: error) }
                            else { continuation.resume() }
                        }
                    }
                }
            ])
            NSApp.terminate(nil)
        } catch {
            for handle in host.handles {
                handle.cancelUninstall()
                handle.setWatched(true)
            }
            host.applySchedule()
            host.autoCleaner.resume()
            throw error
        }
    }
}
