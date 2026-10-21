import CoreServices
import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// The name people know an app by, for a bundle identifier or a folder named after one (`com.steipete.codexbar` is CodexBar).
/// Every module shows names through here, so an identifier is never what a row or a confirmation says. Identifiers stay what
/// matching uses; only the text shown changes.
public enum AppNames {
    /// Where names come from, replaceable so the order below can be tested without the apps on this Mac.
    public struct Lookup: Sendable {
        /// The installed app with this bundle identifier (Launch Services).
        public var appURL: @Sendable (_ bundleIdentifier: String) -> URL?
        /// The apps running now: bundle identifier and the name macOS shows for them.
        public var running: @Sendable () -> [(identifier: String, name: String)]
        /// The app with this bundle identifier wherever Spotlight indexed it, for one Launch Services does not know.
        public var indexedURL: @Sendable (_ bundleIdentifier: String) -> URL?

        public init(appURL: @escaping @Sendable (String) -> URL?, running: @escaping @Sendable () -> [(identifier: String, name: String)],
                    indexedURL: @escaping @Sendable (String) -> URL?) {
            self.appURL = appURL
            self.running = running
            self.indexedURL = indexedURL
        }

        public static let live = Lookup(
            appURL: { identifier in
                #if canImport(AppKit)
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
                #else
                nil
                #endif
            },
            running: {
                #if canImport(AppKit)
                NSWorkspace.shared.runningApplications.compactMap { app in
                    guard let identifier = app.bundleIdentifier, let name = app.localizedName else { return nil }
                    return (identifier, name)
                }
                #else
                []
                #endif
            },
            indexedURL: { identifier in
                guard let query = MDQueryCreate(kCFAllocatorDefault, "kMDItemCFBundleIdentifier == '\(identifier.replacingOccurrences(of: "'", with: ""))'" as CFString, nil, nil) else { return nil }
                MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue))
                guard MDQueryGetResultCount(query) > 0,
                      let item = MDQueryGetResultAtIndex(query, 0),
                      let path = MDItemCopyAttribute(Unmanaged<MDItem>.fromOpaque(item).takeUnretainedValue(), kMDItemPath) as? String else { return nil }
                return URL(fileURLWithPath: path)
            })
    }

    /// Names of apps this Mac cannot resolve by itself (not installed or not running, so nothing to read a name from).
    static let known: [String: String] = [
        "com.steipete.codexbar": "CodexBar",
    ]

    /// What the system adds after an app's identifier for the folders and helpers it keeps for it.
    static let helperSuffixes = [".ShipIt", ".savedState", ".helper", ".Helper", ".HelperTool", ".Updater", ".agent"]

    private static let cache = NameCache()

    /// `raw` as people read it: the app's name when it is an identifier (or a folder named after one), `raw` itself otherwise.
    public static func display(_ raw: String, lookup: Lookup? = nil) -> String {
        guard looksLikeBundleIdentifier(raw) else { return raw }
        return name(for: raw, lookup: lookup)
    }

    /// The app's name for a bundle identifier: the installed app's own, else a running app's, else the app an extension or a helper
    /// belongs to, else Spotlight's, else the built-in table, else the identifier made readable. Never an identifier.
    public static func name(for identifier: String, lookup: Lookup? = nil) -> String {
        // Only the live lookup is remembered: a test's own is not.
        if lookup == nil, let cached = cache.value(identifier) { return cached }
        let found = resolved(identifier, lookup: lookup ?? .live) ?? prettified(identifier)
        if lookup == nil { cache.set(identifier, found) }
        return found
    }

    /// The name the system or the table gives, nil when none does (so a caller can tell a real name from a made-up one).
    public static func resolved(_ identifier: String, lookup: Lookup = .live) -> String? {
        var base = identifier
        // A group container is named `group.<bundle identifier>`, or on macOS `<team identifier>.<bundle identifier>`.
        if base.hasPrefix("group.") { base = String(base.dropFirst("group.".count)) }
        else if let team = base.split(separator: ".").first, team.count == 10, team.allSatisfy({ $0.isNumber || ($0.isUppercase && $0.isLetter) }),
                base.split(separator: ".").count > 3 { base = String(base.dropFirst(team.count + 1)) }
        for suffix in helperSuffixes where base.hasSuffix(suffix) && base.count > suffix.count {
            base = String(base.dropLast(suffix.count))
            break
        }
        if let name = known[base.lowercased()] { return name }
        let running = lookup.running()
        // The identifier itself, then, for an extension or a helper, the app whose identifier its own begins with.
        var parts = base.split(separator: ".").map(String.init)
        while parts.count >= 2 {
            let candidate = parts.joined(separator: ".")
            if let url = lookup.appURL(candidate), let name = bundleName(url) { return name }
            if let app = running.first(where: { $0.identifier.caseInsensitiveCompare(candidate) == .orderedSame }) { return app.name }
            if let name = known[candidate.lowercased()] { return name }
            parts.removeLast()
        }
        if let url = lookup.indexedURL(base), let name = bundleName(url) { return name }
        return nil
    }

    /// The name an app bundle gives itself: its display name (in the user's language when it has one), its name, its file name.
    static func bundleName(_ url: URL) -> String? {
        if let bundle = Bundle(url: url) {
            for key in ["CFBundleDisplayName", "CFBundleName"] {
                if let name = (bundle.localizedInfoDictionary?[key] ?? bundle.infoDictionary?[key]) as? String, !name.isEmpty { return name }
            }
        }
        let file = url.deletingPathExtension().lastPathComponent
        return file.isEmpty ? nil : file
    }

    /// `com.example.app-name` with no name to be found: its last meaningful part, split into words and capitalized (`App name`).
    public static func prettified(_ identifier: String) -> String {
        let generic: Set<String> = ["com", "org", "net", "io", "co", "me", "dev", "app", "apps", "mac", "macos", "osx", "desktop", "helper", "agent", "group"]
        var parts = identifier.split(separator: ".").map(String.init)
        if parts.first == "group" { parts.removeFirst() }
        while parts.count > 1, let last = parts.last, helperSuffixes.contains("." + last) || generic.contains(last.lowercased()) { parts.removeLast() }
        let part = parts.last ?? identifier
        var words = ""
        for character in part {
            if character == "-" || character == "_" { words.append(" ") } else { words.append(character) }
        }
        let text = words.trimmingCharacters(in: .whitespaces)
        guard let first = text.first else { return identifier }
        return first.uppercased() + text.dropFirst()
    }

    /// `com.example.App`: two dots or more, no spaces.
    public static func looksLikeBundleIdentifier(_ name: String) -> Bool {
        name.split(separator: ".").count >= 3 && !name.contains(" ") && !name.contains("/")
    }
}

private final class NameCache: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String: String] = [:]
    func value(_ key: String) -> String? { lock.lock(); defer { lock.unlock() }; return names[key] }
    func set(_ key: String, _ value: String) { lock.lock(); defer { lock.unlock() }; names[key] = value }
}
