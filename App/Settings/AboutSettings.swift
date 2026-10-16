import AppKit
import MacSpacePlatform
import MacSpaceSdk
import ServiceManagement
import SwiftUI

struct AboutSettingsSection: View {
    @ObservedObject var host: ModuleHost
    @State private var uninstalling = false

    var body: some View {
        Section("About") {
            LabeledContent("MacSpace", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
            Link("GitHub", destination: URL(string: "https://github.com/1architect/macspace-releases")!)
            Button(uninstalling ? String(localized: "Restoring settings…") : String(localized: "Uninstall MacSpace…")) {
                let alert = NSAlert()
                alert.messageText = String(localized: "Uninstall MacSpace?")
                alert.informativeText = String(localized: "Restores settings changed by MacSpace and moves the app to the Trash. Your history is kept. Freed files cannot be restored.")
                alert.addButton(withTitle: String(localized: "Cancel"))
                alert.addButton(withTitle: String(localized: "Uninstall"))
                guard alert.runModal() == .alertSecondButtonReturn else { return }
                uninstalling = true
                Task {
                    do { try await AppUninstaller.uninstall(host: host) }
                    catch {
                        let failure = NSAlert()
                        failure.messageText = String(localized: "Couldn’t uninstall MacSpace")
                        failure.informativeText = error.localizedDescription
                        failure.runModal()
                    }
                    uninstalling = false
                }
            }
            .disabled(uninstalling)
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
