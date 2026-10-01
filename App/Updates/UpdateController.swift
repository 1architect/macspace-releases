import Combine
import Foundation
import Sparkle

/// Automatic updates through Sparkle. The update feed and the public key that verifies every download come from the app's
/// Info.plist (`SUFeedURL`, `SUPublicEDKey`). A build without a key, such as a development build, does not check for updates
/// at all, so it can never install anything that was not signed with the release key.
@MainActor
public final class UpdateController: ObservableObject {
    private let controller: SPUStandardUpdaterController?
    private var observation: AnyCancellable?

    @Published public private(set) var canCheck = false

    public static func isConfigured(_ bundle: Bundle = .main) -> Bool {
        guard let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String else { return false }
        return !key.isEmpty && !key.hasPrefix("__")
    }

    public init(bundle: Bundle = .main) {
        if Self.isConfigured(bundle) {
            controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
            observation = controller?.updater.publisher(for: \.canCheckForUpdates).sink { [weak self] value in
                Task { @MainActor in self?.canCheck = value }
            }
        } else {
            controller = nil
        }
    }

    /// False in builds without an update key.
    public var isAvailable: Bool { controller != nil }

    public func checkForUpdates() { controller?.checkForUpdates(nil) }

    public var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set {
            objectWillChange.send()
            controller?.updater.automaticallyChecksForUpdates = newValue
        }
    }
}
