import AppKit
import Combine
import MacSpacePlatform
import MacSpaceSdk
import SwiftUI

/// Workspace notifications update the small in-use pill without rescanning disk contents.
@MainActor
final class RunningApplications: ObservableObject {
    static let shared = RunningApplications()
    @Published private(set) var paths = Set<String>()
    private var notifications: AnyCancellable?

    init() {
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        notifications = center.publisher(for: NSWorkspace.didLaunchApplicationNotification)
            .merge(with: center.publisher(for: NSWorkspace.didTerminateApplicationNotification))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
    }

    private func refresh() {
        paths = Set(NSWorkspace.shared.runningApplications.compactMap {
            ($0.bundleURL ?? $0.executableURL).map { FileReviewPolicy.livePath($0.resolvingSymlinksInPath().path) }
        })
    }

    static func contains(_ app: String, paths: Set<String>) -> Bool {
        let app = FileReviewPolicy.livePath(app)
        return paths.contains { $0 == app || $0.hasPrefix(app + "/") }
    }
}

struct AppUseBadge: View {
    let path: String
    let appeared: Bool
    @ObservedObject private var running = RunningApplications.shared

    var body: some View {
        RowBadges(badges: RunningApplications.contains(path, paths: running.paths)
            ? [Badge(String(localized: "In use"), .info, help: String(localized: "MacSpace quits this app before uninstalling it."))] : [],
                  gap: 6, arrives: appeared)
    }
}
