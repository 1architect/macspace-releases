import AppKit
import Darwin
import Foundation

/// Closes what keeps the chosen caches in use, so the caches can be freed. The confirmation names them first (`CachesPage.quitNote`,
/// `Selection.noteNames`). By the cleaner's own rule of what keeps a cache (`ProcessCheck.runningOwner`), never by a list of apps, so
/// it holds for apps MacSpace has never seen:
///
/// - an app, whether it shows in the Dock, the menu bar or nowhere (a plug-in's renderer), is asked to quit as the user would quit it:
///   it can ask to save, and the user can cancel, which leaves its cache;
/// - a program that is not an app (a command-line tool), found by the owner's name, is asked to end (`SIGTERM`), as closing its
///   Terminal window would.
///
/// Never one of macOS's programs, never MacSpace. MacSpace does not open them again: the user does, when they want them.
enum AppQuitter {
    /// The running apps that own a cache (`RunningApp.owns`): by bundle identifier, or, unless `exact` (a container, named after its
    /// app), by the app's name. Never one of macOS's, never MacSpace.
    static func owning(_ owners: [String], exact: Bool, apps: [RunningApp]) -> [Int] {
        apps.indices.filter { index in
            let app = apps[index]
            if app.system { return false }
            if let identifier = app.bundleIdentifier, identifier.hasPrefix("com.macspace.") || identifier.hasPrefix("com.apple.") { return false }
            return owners.contains { app.owns($0, exact: exact) }
        }
    }

    /// The programs that are not apps and own a cache: a process with an owner's exact name (`ProcessCheck.runningOwner`'s rule), the
    /// user's own, never one of macOS's programs, never MacSpace, never one the apps list already has.
    static func tools(_ owners: [String], processes: [RunningProcess], appPIDs: Set<pid_t>, ownPID: pid_t = getpid()) -> [RunningProcess] {
        processes.filter { process in
            process.pid != ownPID && !appPIDs.contains(process.pid) && !ProcessCheck.isAppleSystemProgram(process.executablePath)
                && owners.contains { process.name.caseInsensitiveCompare($0) == .orderedSame }
        }
    }

    /// Closes what owns the cache and waits for it and its helpers (the processes running from inside the apps' bundles), up to
    /// `timeout`. False when something is still running: an app asked to save and the user kept it open, or a tool did not end.
    static func quit(_ owners: [String], exact: Bool, timeout: TimeInterval = 30) async -> Bool {
        let running = NSWorkspace.shared.runningApplications
        let apps = owning(owners, exact: exact, apps: running.map {
            RunningApp(bundleIdentifier: $0.bundleIdentifier, name: $0.localizedName, system: RunningApp.isSystem($0.bundleURL))
        }).map { running[$0] }
        let tools = exact ? [] : tools(owners, processes: ProcessCheck.live.processes() ?? [], appPIDs: Set(running.map(\.processIdentifier)))
        guard !apps.isEmpty || !tools.isEmpty else { return true }
        let bundles = apps.compactMap { $0.bundleURL?.standardizedFileURL.path }.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        for app in apps { app.terminate() }
        for tool in tools { kill(tool.pid, SIGTERM) }
        let deadline = Date().addingTimeInterval(timeout)
        while apps.contains(where: { !$0.isTerminated }) || tools.contains(where: { kill($0.pid, 0) == 0 }) {
            guard Date() < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(250))
        }
        // Their helpers and extensions end a moment after them; the cleaner skips a cache while one still runs.
        let helpersDeadline = Date().addingTimeInterval(10)
        while Date() < helpersDeadline {
            let processes = ProcessCheck.live.processes() ?? []
            guard processes.contains(where: { process in bundles.contains { process.executablePath?.hasPrefix($0) == true } }) else { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return true
    }
}
