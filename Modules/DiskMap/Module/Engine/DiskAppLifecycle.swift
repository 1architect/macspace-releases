import AppKit
import Foundation
import MacSpacePlatform

enum DiskAppLifecycle {
    struct Running: Equatable, Sendable {
        var pid: pid_t
        var bundlePath: String?
        var executablePath: String?
    }

    static func belongs(_ process: Running, to app: String) -> Bool {
        let app = FileReviewPolicy.livePath(app)
        return [process.bundlePath, process.executablePath].compactMap { $0 }.contains {
            let path = FileReviewPolicy.livePath($0)
            return path == app || path.hasPrefix(app + "/")
        }
    }

    @MainActor
    struct Client {
        var running: () -> [Running]
        var terminate: (Running) -> Bool
        var pause: () async throws -> Void = { try await Task.sleep(for: .milliseconds(100)) }
        var now: () -> Date = Date.init

        static var live: Client {
            Client(running: {
                NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }.map { app in
                    Running(pid: app.processIdentifier,
                            bundlePath: app.bundleURL?.resolvingSymlinksInPath().path,
                            executablePath: app.executableURL?.resolvingSymlinksInPath().path)
                }
            }, terminate: { process in
                guard let app = NSRunningApplication(processIdentifier: process.pid), !app.isTerminated else { return true }
                // A PID may have been reused since discovery; never quit a different installation.
                guard app.bundleURL?.resolvingSymlinksInPath().path == process.bundlePath,
                      app.executableURL?.resolvingSymlinksInPath().path == process.executablePath else { return false }
                return app.terminate()
            })
        }
    }

    /// Ask normally so the app can save documents or cancel. No force quit, and no removal
    /// proceeds until every matching running application, including embedded apps, has ended.
    @MainActor
    static func quit(_ paths: [String], timeout: TimeInterval = 30, client: Client? = nil) async -> Bool {
        let client = client ?? .live
        let deadline = client.now().addingTimeInterval(timeout)
        var requested = Set<pid_t>()
        while true {
            guard !Task.isCancelled else { return false }
            let running = client.running().filter { process in paths.contains { belongs(process, to: $0) } }
            if running.isEmpty { return true }
            guard client.now() < deadline else { return false }
            for process in running where requested.insert(process.pid).inserted {
                guard client.terminate(process) else { return false }
            }
            do { try await client.pause() } catch { return false }
        }
    }
}
