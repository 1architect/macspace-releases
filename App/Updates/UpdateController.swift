import Combine
import Foundation
import Sparkle

/// Automatic updates through Sparkle. The update feed and the public key that verifies every download come from the app's
/// Info.plist (`SUFeedURL`, `SUPublicEDKey`). A build without a key, such as a development build, does not check for updates
/// at all, so it can never install anything that was not signed with the release key.
@MainActor
public final class UpdateController: ObservableObject {
    private let updater: SPUUpdater?
    private let userDriver: UpdateUserDriver?
    private var observation: AnyCancellable?

    @Published public private(set) var canCheck = false

    public static func isConfigured(_ bundle: Bundle = .main) -> Bool {
        guard let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String else { return false }
        return !key.isEmpty && !key.hasPrefix("__")
    }

    public init(bundle: Bundle = .main) {
        if Self.isConfigured(bundle) {
            let driver = UpdateUserDriver(hostBundle: bundle, delegate: nil)
            let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: nil)
            do { try updater.start() } catch { NSLog("MacSpace: the updater did not start: %@", error.localizedDescription) }
            self.updater = updater
            userDriver = driver
            observation = updater.publisher(for: \.canCheckForUpdates).sink { [weak self] value in
                Task { @MainActor in self?.canCheck = value }
            }
        } else {
            updater = nil
            userDriver = nil
        }
    }

    /// False in builds without an update key.
    public var isAvailable: Bool { updater != nil }

    public func checkForUpdates() { updater?.checkForUpdates() }

    public var automaticallyChecks: Bool {
        get { updater?.automaticallyChecksForUpdates ?? false }
        set {
            objectWillChange.send()
            updater?.automaticallyChecksForUpdates = newValue
        }
    }
}

/// Sparkle's own windows, except the one that says there is nothing new. Sparkle's says "MacSpace 1.1.2 is currently the newest
/// version available" and, when the running build is newer than the feed, adds "(You are currently running version 1.1.3.)": a
/// sentence its Portuguese and other translations lack, so it came up in English (2026-10-19). MacSpace says it in one line of
/// its own, in its own alert and languages, with no version numbers. Errors (no connection, a feed it cannot read) keep Sparkle's.
final class UpdateUserDriver: SPUStandardUserDriver {
    override func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        // Only "nothing new": a Mac too old or too new for the latest version keeps Sparkle's explanation.
        let reason = ((error as NSError).userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber).flatMap { SPUNoUpdateFoundReason(rawValue: $0.int32Value) }
        guard reason == .onLatestVersion || reason == .onNewerThanLatestVersion else {
            super.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement)
            return
        }
        let alert = AppAlert()
        alert.messageText = String(localized: "MacSpace is up to date")
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
        acknowledgement()
    }
}
