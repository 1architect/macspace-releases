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

/// Sparkle's own windows, as MacBat shows them. One sentence is changed: with the running build newer than the newest release in the
/// feed (a build made before its release is published), Sparkle adds "(You are currently running version 1.1.3.)", a sentence its
/// Portuguese and most other translations lack, so the box came up in English (2026-10-19). It says Sparkle's own short sentence
/// instead, from Sparkle's own translations, as it does for the newest version: "MacSpace 1.1.2 é a versão mais recente disponível."
final class UpdateUserDriver: SPUStandardUserDriver {
    override func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        let error = error as NSError
        guard let reason = (error.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber).flatMap({ SPUNoUpdateFoundReason(rawValue: $0.int32Value) }),
              reason == .onNewerThanLatestVersion,
              let latest = error.userInfo[SPULatestAppcastItemFoundKey] as? SUAppcastItem else {
            super.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement)
            return
        }
        let sparkle = Bundle(for: SPUUpdater.self)
        let format = sparkle.localizedString(forKey: "%@ %@ is currently the newest version available.", value: nil, table: "Sparkle")
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "MacSpace"
        var info = error.userInfo
        info[NSLocalizedRecoverySuggestionErrorKey] = String(format: format, name, latest.displayVersionString)
        super.showUpdateNotFoundWithError(NSError(domain: error.domain, code: error.code, userInfo: info), acknowledgement: acknowledgement)
    }
}
