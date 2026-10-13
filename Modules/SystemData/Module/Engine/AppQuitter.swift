import AppKit
import Foundation

/// Quits the app that keeps a cache open, so the cache can be freed, and opens it again afterwards (the row's Free on an open app's
/// cache). The app is asked to quit as the user would quit it: it can ask to save, and the user can cancel, which leaves its cache.
enum AppQuitter {
    /// The running apps that own a cache, by the cleaner's own rule (`ProcessCheck`): by bundle identifier, or, unless `exact` (a
    /// container, named after its app), by the app's name. MacSpace and the Finder are never quit.
    static func owning(_ owners: [String], exact: Bool, apps: [RunningApp]) -> [Int] {
        apps.indices.filter { index in
            let app = apps[index]
            if let identifier = app.bundleIdentifier, identifier.hasPrefix("com.macspace.") || identifier == "com.apple.finder" { return false }
            return owners.contains { owner in
                if app.bundleIdentifier?.caseInsensitiveCompare(owner) == .orderedSame { return true }
                guard !exact, let name = app.name else { return false }
                return name.caseInsensitiveCompare(owner) == .orderedSame || owner.lowercased().contains(name.lowercased()) && name.count >= 4
            }
        }
    }

    /// Asks the owning apps to quit and waits for them, up to `timeout`. Returns the apps' locations, to open them again, or nil when
    /// none is running as an app (a helper or a command-line tool holds the cache) or one did not quit in time (it asked to save and
    /// the user kept it open).
    static func quit(_ owners: [String], exact: Bool, timeout: TimeInterval = 30) async -> [URL]? {
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy != .prohibited }
        let chosen = owning(owners, exact: exact, apps: running.map { RunningApp(bundleIdentifier: $0.bundleIdentifier, name: $0.localizedName) })
            .map { running[$0] }
        guard !chosen.isEmpty else { return nil }
        let urls = chosen.compactMap(\.bundleURL)
        for app in chosen { app.terminate() }
        let deadline = Date().addingTimeInterval(timeout)
        while chosen.contains(where: { !$0.isTerminated }) {
            guard Date() < deadline else { return nil }
            try? await Task.sleep(for: .milliseconds(250))
        }
        // Their helpers end a moment after them.
        try? await Task.sleep(for: .seconds(1))
        return urls
    }

    /// Opens the apps again, behind MacSpace.
    static func reopen(_ urls: [URL]) async {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        for url in urls { _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration) }
    }
}
