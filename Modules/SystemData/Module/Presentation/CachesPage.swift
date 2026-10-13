import Foundation
import MacSpacePlatform
import MacSpaceSdk

/// One cache the user can free: an app's cache, an app's web cache, a per-user system cache, a developer tool's cache, or Homebrew's
/// leftovers. Each is listed on the caches page only (`CachesPage`), never again in a block's or a category's page.
struct CacheEntry: Equatable {
    enum Source: Equatable {
        case app, web, system, developer, homebrew

        /// Its pill under Recommended, where caches of every kind are mixed.
        var title: String {
            switch self {
            case .app: return loc("App cache")
            case .web: return loc("Web cache")
            case .system: return loc("System cache")
            case .developer: return loc("Developer")
            case .homebrew: return "Homebrew"
            }
        }
    }

    /// The parts of the page, in the order drawn.
    enum Part: String, CaseIterable {
        case recommended, apps, developer
    }

    var id: String
    var title: String
    var bytes: UInt64
    var paths: [String]
    var source: Source
    /// MacSpace recommends freeing it: checked until the user chooses.
    var recommended = false
    /// Why, as a pill, when the category does not say it.
    var reason: String?
    /// Its other pills, outside Recommended ("Open now", "Unknown app").
    var facts: [String] = []
    /// Its app or tool is open: it can only be freed once that quits, so it has no box.
    var open = false
    /// The scanned item that holds it (`SystemDataItem.id`), whose block and listing it is taken out of; nil when it is in none (a
    /// developer folder System Settings counts under Developer).
    var within: String?
    /// It stands for the whole of that item, not only its own size: Homebrew's downloads are its cache folder, whose rest (its
    /// package list) nothing frees, so the folder is not listed again for what is left.
    var wholeItem = false

    /// The part it belongs to when it is not recommended.
    var home: Part { source == .developer || source == .homebrew ? .developer : .apps }
}

enum CachesPage {
    /// Every cache the page lists, largest first.
    static func entries(_ snapshot: SystemDataSnapshot, now: Date = Date()) -> [CacheEntry] {
        var entries: [CacheEntry] = []
        let report = snapshot.report

        // Third-party caches in ~/Library/Caches (`AppCaches.outcome`). What looks like data is never listed.
        let listed = report.appCaches.filter { $0.bytes >= SystemDataScreenBuilder.worthARow && AppCaches.outcome($0, now: now) != .heldBack }
        // Two folders of one app (Sublime Text's own and `com.sublimetext.4`) are told apart by their folder names.
        var titles: [String: Int] = [:]
        for cache in listed { titles[cache.title, default: 0] += 1 }
        for cache in listed {
            let outcome = AppCaches.outcome(cache, now: now)
            let days = AppCaches.unchangedDays(cache, now: now)
            var entry = CacheEntry(id: cache.id, title: titles[cache.title, default: 0] > 1 ? cache.name : cache.title, bytes: cache.bytes,
                                   paths: [cache.path], source: .app, within: cache.id)
            if outcome == .suggested {
                entry.recommended = true
                switch cache.owner {
                case .notInstalled: entry.reason = loc("App not installed")
                case let .app(_, lastOpened?) where now.timeIntervalSince(lastOpened) / 86_400 >= Double(days):
                    entry.reason = loc("Not opened for \(max(0, Int(now.timeIntervalSince(lastOpened) / 86_400))) days")
                default: entry.reason = loc("Unchanged for \(days) days")
                }
            } else if cache.owner == .unknown {
                entry.facts = [loc("Unknown app")]
            }
            if cache.ownerRunning { open(&entry) }
            entries.append(entry)
        }

        // The web caches of Chromium and Electron apps, and the per-user system caches of third-party tools: what Clean always freed
        // while their app was closed, so recommended.
        for item in report.items where item.cleanup.kind == .deleteWhenNotRunning && (item.id.hasPrefix("supportcache:") || item.id.hasPrefix("usercache:")) {
            let bytes = item.expectedReclaimBytes ?? item.bytes ?? 0
            guard bytes >= SystemDataScreenBuilder.worthARow else { continue }
            let web = item.id.hasPrefix("supportcache:")
            var entry = CacheEntry(id: item.id, title: String(item.id.drop { $0 != ":" }.dropFirst()), bytes: bytes, paths: item.paths,
                                   source: web ? .web : .system, recommended: true, within: item.id)
            if item.inUse { open(&entry) }
            entries.append(entry)
        }

        // Developer tools' caches; those in ~/Library/Developer are System Settings' Developer, in no System Data item.
        for cache in snapshot.developerCaches {
            entries.append(CacheEntry(id: cache.id, title: cache.title, bytes: cache.bytes, paths: cache.paths, source: .developer,
                                      recommended: cache.recommended, reason: cache.reason, within: containingItem(cache.paths.first, report)))
        }

        // Homebrew's own cleanup: old versions (recommended), and every download, which Homebrew fetches again when it needs one.
        if let plan = snapshot.homebrew {
            let old = plan.standard.bytes.flatMap { $0 >= SystemDataScreenBuilder.worthARow ? $0 : nil }
            if let old {
                entries.append(CacheEntry(id: homebrewOld, title: loc("Old Homebrew versions"), bytes: old, paths: [], source: .homebrew,
                                          recommended: true, within: "packages:homebrew"))
            }
            if let all = plan.allDownloads.bytes, all > (old ?? 0), all - (old ?? 0) >= SystemDataScreenBuilder.worthARow {
                let downloads = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/Homebrew").path
                entries.append(CacheEntry(id: homebrewDownloads, title: loc("Homebrew downloads"), bytes: all - (old ?? 0), paths: [downloads],
                                          source: .homebrew, recommended: true, reason: loc("Downloads again when needed"),
                                          within: "appcache:Homebrew", wholeItem: true))
            }
        }
        // A cache too small to be an item of its own is part of its kind's "Smaller items" (`SmallKey`).
        let itemIDs = Set(report.items.map(\.id))
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for index in entries.indices where entries[index].within.map({ !itemIDs.contains($0) }) ?? true {
            guard let path = entries[index].paths.first else { continue }
            if path.hasPrefix(home + "/Library/Caches/") { entries[index].within = SmallKey(kind: .appCache).id }
            else if path.hasPrefix(home + "/.cache/") { entries[index].within = SmallKey(kind: .toolCache).id }
            else if path.hasPrefix(home + "/."), entries[index].within == nil { entries[index].within = SmallKey(kind: .appSupport).id }
        }
        return entries.sorted { $0.bytes > $1.bytes }
    }

    static let homebrewOld = "homebrew:old"
    static let homebrewDownloads = "homebrew:downloads"

    /// An open app's cache: not freeable now, so not recommended, and its reason stays as a fact.
    private static func open(_ entry: inout CacheEntry) {
        entry.facts = [loc("Open now")] + [entry.reason].compactMap { $0 } + entry.facts
        entry.recommended = false
        entry.reason = nil
        entry.open = true
    }

    /// The scanned item whose folders hold `path`: the deepest one.
    static func containingItem(_ path: String?, _ report: SystemDataReport) -> String? {
        guard let path else { return nil }
        var best: (id: String, length: Int)?
        for item in report.items {
            for folder in item.paths where path == folder || path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/") {
                if folder.count > best?.length ?? -1 { best = (item.id, folder.count) }
            }
        }
        return best?.id
    }

    // MARK: Choice

    /// The part each cache is listed in.
    static func part(_ entry: CacheEntry) -> CacheEntry.Part { entry.recommended ? .recommended : entry.home }

    /// A cache of an open app cannot be chosen until the app quits.
    static func choosable(_ entry: CacheEntry) -> Bool { !entry.open }

    /// The caches checked: the user's choice, with every cache of a part whose header box is on, or MacSpace's recommendation.
    static func checked(_ entries: [CacheEntry], _ choices: CacheChoices) -> Set<String> {
        let candidates = entries.filter(choosable)
        guard let chosen = choices.chosen else { return Set(candidates.filter(\.recommended).map(\.id)) }
        return Set(candidates.filter { chosen.contains($0.id) || choices.all.contains(part($0).rawValue) }.map(\.id))
    }

    /// What the page's main Free button and automatic cleaning free.
    static func chosen(_ snapshot: SystemDataSnapshot, now: Date = Date()) -> [CacheEntry] {
        let all = entries(snapshot, now: now)
        let ids = checked(all, snapshot.choices)
        return all.filter { ids.contains($0.id) }
    }

    static func chosenBytes(_ snapshot: SystemDataSnapshot, now: Date = Date()) -> UInt64 {
        chosen(snapshot, now: now).map(\.bytes).reduce(0, +)
    }

    // MARK: Page

    /// The caches page, as a group row of Free now: Recommended, then the apps' caches, then the developer caches, each largest
    /// first, each with a box that checks the whole part. nil when there is no cache to list.
    static func row(_ snapshot: SystemDataSnapshot, now: Date = Date()) -> Row? {
        let all = entries(snapshot, now: now)
        guard !all.isEmpty else { return nil }
        let choices = snapshot.choices
        var rows: [Row] = []
        var sections: [SelectionSection] = []
        for part in CacheEntry.Part.allCases {
            let members = all.filter { self.part($0) == part }
            guard !members.isEmpty else { continue }
            let partRows = members.map { row($0, part: part) }
            rows += partRows
            let count = members.count == 1 ? loc("1 item") : loc("\(members.count) items")
            let title = [partTitle(part), count, ByteFormat.string(members.map(\.bytes).reduce(0, +))].joined(separator: " · ")
            sections.append(SelectionSection(id: part.rawValue, title: title, rows: partRows.map(\.id), all: choices.all.contains(part.rawValue)))
        }
        var group = Row.group(id: groupID, title: loc("Caches you can free"), totalBytes: all.map(\.bytes).reduce(0, +), rows: rows)
        let choosable = all.filter(self.choosable)
        group.selection = Selection(
            action: Action(id: "freeCaches", title: loc("Free selected"), confirmation: Confirmation(
                title: loc("Free the selected caches?"), message: loc("Apps rebuild their caches. They may open more slowly the first time."),
                confirmTitle: loc("Free"))),
            choices: Dictionary(choosable.map { ($0.id, $0.bytes) }, uniquingKeysWith: { first, _ in first }),
            checked: checked(all, choices).sorted(),
            suggested: choosable.filter(\.recommended).map(\.id),
            suggestedTitle: loc("Free recommended"),
            sections: sections,
            save: Action(id: "saveCacheChoice", title: loc("Free selected")))
        return group
    }

    static let groupID = "caches"

    static func partTitle(_ part: CacheEntry.Part) -> String {
        switch part {
        case .recommended: return loc("Recommended")
        case .apps: return loc("Come back with use")
        case .developer: return loc("Developer")
        }
    }

    /// A cache as a row: its pills (where it comes from and why, under Recommended; its state elsewhere) and its folder. No (i):
    /// the pills say it.
    static func row(_ entry: CacheEntry, part: CacheEntry.Part) -> Row {
        let badges = part == .recommended ? [entry.source.title] + [entry.reason].compactMap { $0 } : entry.facts
        return Row(id: entry.id, title: entry.title, trailing: ByteFormat.string(entry.bytes), badges: badges.map { Badge($0) }, paths: entry.paths)
    }

    // MARK: What the page takes out of the rest

    /// What the listed caches take out of each scanned item, by item id: an item wholly made of one (an app's cache folder) is
    /// listed on the caches page only; one holding some (Homebrew's packages, a tool's hidden folder) is listed with what is left.
    /// For a block (`wholeItems` false), only what each cache frees counts.
    static func claimed(_ snapshot: SystemDataSnapshot, wholeItems: Bool = true) -> [String: UInt64] {
        var claimed: [String: UInt64] = [:]
        for entry in entries(snapshot) {
            guard let within = entry.within else { continue }
            let whole = entry.wholeItem && wholeItems ? snapshot.report.items.first { $0.id == within }?.bytes : nil
            claimed[within, default: 0] += max(entry.bytes, whole ?? 0)
        }
        return claimed
    }
}
