import Foundation

/// What the user chose on the caches page, kept between launches: the checked caches (nil until a box is clicked, when MacSpace's
/// recommendation stands) and the sections whose header box is on (caches that join them later are checked too). The page's main
/// Free button and automatic cleaning free this choice.
struct CacheChoices: Equatable, Sendable {
    var chosen: Set<String>?
    var all: Set<String> = []

    static let chosenKey = "systemData.caches.chosen"
    static let allKey = "systemData.caches.all"

    static func load(_ defaults: UserDefaults = .standard) -> CacheChoices {
        CacheChoices(chosen: (defaults.array(forKey: chosenKey) as? [String]).map(Set.init),
                     all: Set(defaults.stringArray(forKey: allKey) ?? []))
    }

    func save(_ defaults: UserDefaults = .standard) {
        if let chosen { defaults.set(chosen.sorted(), forKey: Self.chosenKey) } else { defaults.removeObject(forKey: Self.chosenKey) }
        defaults.set(all.sorted(), forKey: Self.allKey)
    }
}

/// What the system log keeps after an erase: the format strings of the programs still running, which logd keeps (548 MB of 1.41 GB on
/// 26B5101f, 2026-10-13). Measured after each erase and kept, so the page offers only what grew past it: on 2026-10-13 the row said
/// 749 MB right after an erase, and its Free freed a few kilobytes.
enum SystemLogFloor {
    static let key = "systemData.log.floor"

    static func load(_ defaults: UserDefaults = .standard) -> UInt64? {
        (defaults.object(forKey: key) as? NSNumber)?.uint64Value
    }

    static func save(_ bytes: UInt64, _ defaults: UserDefaults = .standard) {
        defaults.set(NSNumber(value: bytes), forKey: key)
    }
}
