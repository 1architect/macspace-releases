import AppKit
import Foundation
import MacSpaceSdk

/// Who frees the caches of the caches page, as chosen in Settings › System Data: no one (the switch is off, and the caches are listed
/// with the rest of what is in System Data), MacSpace, or another cleaner the user has installed, which MacSpace only sizes and opens.
enum CacheCleaner: Equatable, Sendable {
    case off
    case macSpace
    /// Another app frees them: the page shows what can be freed and a button that opens it.
    case app(name: String, url: URL)

    static let switchID = "cacheCleanup"
    static let choiceID = "cacheCleaner"

    /// The Settings choice, with the app it names. A cleaner that is no longer installed falls back to MacSpace.
    static func read(_ context: ModuleContext,
                     locate: (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }) -> CacheCleaner {
        guard context.options.bool(switchID) else { return .off }
        let chosen = context.options.string(choiceID)
        guard case let .choice(choices, _)? = context.manifest.options.first(where: { $0.id == choiceID })?.kind,
              let choice = choices.first(where: { $0.id == chosen }), let apps = choice.apps,
              let url = apps.lazy.compactMap(locate).first else { return .macSpace }
        return .app(name: choice.title, url: url)
    }
}
