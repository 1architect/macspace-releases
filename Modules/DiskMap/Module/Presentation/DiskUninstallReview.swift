import Foundation
import Darwin
import MacSpaceSdk
import MacSpacePlatform
import MacSpaceDiskMapPrivileged

enum DiskUninstallReview {
    enum Category: String, CaseIterable {
        case caches, support, preferences, containers, scripts, cookies, web, logs, savedState, startup, other

        var title: String {
            switch self {
            case .caches: loc("Caches")
            case .support: loc("Application support")
            case .preferences: loc("Preferences")
            case .containers: loc("App containers")
            case .scripts: loc("Application scripts")
            case .cookies: loc("Cookies")
            case .web: loc("Web data")
            case .logs: loc("Logs")
            case .savedState: loc("Saved application state")
            case .startup: loc("Startup items")
            case .other: loc("Other app data")
            }
        }

        static func of(_ path: String, home: String) -> Category {
            let path = FileReviewPolicy.livePath(path)
            guard let library = [home + "/Library/", "/Library/"].first(where: path.hasPrefix) else { return .other }
            switch path.dropFirst(library.count).split(separator: "/").first {
            case "Caches": return .caches
            case "Application Support": return .support
            case "Preferences": return .preferences
            case "Containers", "Group Containers": return .containers
            case "Application Scripts": return .scripts
            case "Cookies": return .cookies
            case "HTTPStorages", "WebKit": return .web
            case "Logs": return .logs
            case "Saved Application State": return .savedState
            default: return .other
            }
        }
    }

    private struct Item {
        var row: Row
        var bytes: UInt64
        var category: Category
        var selectable: Bool
    }

    static func screen(_ index: DiskIndex, selected: [DiskApplication], apps: DiskApplications, home: String) -> Screen {
        let selected = selected.sorted { $0.bytes == $1.bytes ? $0.owner.path < $1.owner.path : $0.bytes > $1.bytes }
        let plans = selected.compactMap(DiskUninstallBatch.plan)
        guard plans.count == selected.count, !plans.isEmpty, let encoded = try? JSONEncoder().encode(plans) else {
            return Screen(title: loc("Review app data"), widgets: [])
        }
        let message = loc("MacSpace quits the selected apps before uninstalling them. Unselected and shared data is preserved.")
            + "\n\n" + String(format: loc("Selected apps: %@"), ListFormatter.localizedString(byJoining: selected.map { $0.owner.name }))
            + "\n\n" + (FileRemovalSettings.movesToTrash() ? loc("Selected app data will be moved to Trash.") : loc("Selected app data will be permanently deleted."))
        let action = Action(id: "uninstallSelected", title: loc("Uninstall"), role: .destructive,
            parameters: ["plans": String(decoding: encoded, as: UTF8.self), "trash": FileRemovalSettings.movesToTrash() ? "1" : "0"],
            confirmation: Confirmation(title: loc("Uninstall selected apps?"), message: message, confirmTitle: loc("Uninstall")),
            requires: [.fullDiskAccess, .privilegedHelper], workingTitle: loc("Uninstalling"))
        let candidates = DiskUninstallBatch.dataCandidates(selected, apps: apps, home: home)
        let byPath = Dictionary(uniqueKeysWithValues: candidates.map { ($0.path, $0) })
        var measured: [String: UInt64] = [:]
        func bytes(_ path: String, live: Bool) -> UInt64 {
            if let cached = measured[path] { return cached }
            // A cached allocation must not resurrect a preference/cookie file emptied since scanning.
            var info = stat()
            let exists = lstat(path, &info) == 0
            if exists, info.st_flags & UInt32(SF_DATALESS) != 0 { measured[path] = 0; return 0 }
            if exists, info.st_mode & S_IFMT == S_IFREG {
                let value = info.st_flags & UInt32(SF_DATALESS) == 0 ? UInt64(max(0, info.st_blocks)) * 512 : 0
                measured[path] = value
                return value
            }
            if info.st_mode & S_IFMT == S_IFDIR, isEmptyDirectory(path) {
                measured[path] = 0; return 0
            }
            let cached = DiskApplications.measuredBytes([path], index: index)
            let value = cached > 0 || !live ? cached : FileTreeSizer(refusesLinks: true).size(at: URL(fileURLWithPath: path))?.bytes ?? 0
            measured[path] = value
            return value
        }
        var choices: [String: UInt64] = [:], names: [String: String] = [:]
        var includedBytes: UInt64 = 0
        var checked: [String] = [], sections: [SelectionSection] = []
        var suggestedCaches = 0
        var items: [String: [Item]] = [:]
        for (app, plan) in zip(selected, plans) {
            let owner = app.owner.path
            let mandatory = plan.targets.filter { $0.path != owner }.reduce(0) { $0 + bytes($1.path, live: true) }
            includedBytes += (app.bytes > 0 ? app.bytes : bytes(owner, live: true)) + mandatory
            let claims = app.ownership.filter { $0.source != "bundle" && !$0.source.hasPrefix("receiptManifest") && $0.source != "startupItem" }
            let paths = AppOwnership.normalizedPaths(claims.flatMap(\.paths)).filter { $0 != owner && !$0.hasPrefix(owner + "/") }
            for path in paths {
                let candidate = byPath[path], size = bytes(path, live: candidate != nil)
                guard size > 0 else { continue }
                let category = Category.of(path, home: home)
                let id = candidate?.id ?? "preserved:" + owner + ":" + path
                let shared = claims.contains { $0.paths.contains(path) && $0.confidence == .shared }
                let suggested = candidate != nil && disposableCache(path, app: app, home: home)
                let row = Row(id: id, title: (path as NSString).lastPathComponent,
                    subtitle: path.hasPrefix(home + "/Library/") ? String(path.dropFirst((home + "/Library/").count)) : path,
                    trailing: ByteFormat.string(size), paths: [path],
                    unavailableReason: candidate == nil ? (shared ? loc("Used by other apps") : path.hasPrefix(home + "/Library/") ? loc("Protected or unreadable data") : loc("Outside your user Library")) : nil)
                items[owner, default: []].append(Item(row: row, bytes: size, category: category, selectable: candidate != nil))
                if candidate != nil {
                    choices[id] = size; names[id] = path
                    // Match the removal batch's existing 32-location bound; additional caches remain opt-in.
                    if suggested && suggestedCaches < 32 { checked.append(id); suggestedCaches += 1 }
                }
            }
            for startup in plan.startupItems ?? [] {
                let size = bytes(startup.path, live: true)
                let row = Row(id: "startup:" + startup.path, title: startup.label, trailing: ByteFormat.string(size),
                              paths: [startup.path], unavailableReason: loc("Included with the app"))
                items[owner, default: []].append(Item(row: row, bytes: size, category: .startup, selectable: false))
            }
            for category in Category.allCases {
                let values = items[owner, default: []].filter { $0.category == category }
                guard !values.isEmpty else { continue }
                let reason = values.contains(where: \.selectable) ? nil : values.first?.row.unavailableReason
                // Sections also retain preserved rows so every category has a real detail inventory.
                sections.append(.init(id: categoryID(owner, category), title: category.title, rows: values.map { $0.row.id },
                    all: category == .startup, unavailableReason: reason))
            }
            let optional = items[owner, default: []].filter(\.selectable).map { $0.row.id }
            sections.append(.init(id: dataSectionID(owner), title: loc("\(app.owner.name) app data"), rows: optional,
                                  unavailableReason: optional.isEmpty ? loc("No app data to remove") : nil))
        }
        let selection = Selection(action: action, choices: choices, checked: checked, sections: sections,
            noteNames: names, note: message.replacingOccurrences(of: "%", with: "%%") + "\n\n" + loc("Selected app data: %@"),
            scope: "uninstall-review:" + selected.map { $0.owner.path }.sorted().joined(separator: "\n"), includedBytes: includedBytes)
        var widgets: [ScreenWidget] = []
        for app in selected {
            let owner = app.owner.path
            let groups = Dictionary(grouping: items[owner, default: []], by: \.category)
            let categories = groups.keys.sorted {
                let a = groups[$0, default: []].reduce(0) { $0 + $1.bytes }, b = groups[$1, default: []].reduce(0) { $0 + $1.bytes }
                return a == b ? $0.rawValue < $1.rawValue : a > b
            }
            let rows = categories.map { category in
                let values = groups[category, default: []].sorted { $0.bytes == $1.bytes ? $0.row.id < $1.row.id : $0.bytes > $1.bytes }
                return Row(id: categoryID(owner, category), title: category.title,
                           trailing: ByteFormat.string(values.reduce(0) { $0 + $1.bytes }), children: values.map(\.row),
                           selection: selection, selectionSectionID: categoryID(owner, category))
            }
            widgets.append(.list(ListWidget(id: "uninstall-data:" + owner, title: loc("\(app.owner.name) app data"),
                emptyMessage: loc("No app data to remove"), rows: rows,
                headingChoice: dataSectionID(owner), headingIconPath: owner, cascadesOnAppear: true)))
        }
        return Screen(title: selected.count == 1 ? selected[0].owner.name : loc("Review app data"), layout: .singleColumn,
                      widgets: widgets, selection: selection)
    }

    static func categoryID(_ owner: String, _ category: Category) -> String { "uninstall-category:" + owner + ":" + category.rawValue }
    static func dataSectionID(_ owner: String) -> String { "uninstall-all-data:" + owner }

    private static func isEmptyDirectory(_ path: String) -> Bool {
        guard let directory = opendir(path) else { return false }
        defer { closedir(directory) }
        while true {
            errno = 0
            guard let entry = readdir(directory) else { return errno == 0 }
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) }
            }
            if name != "." && name != ".." { return false }
        }
    }

    /// Disposable-cache evidence is separate from global data ownership. Normal discovery
    /// deliberately labels conventional paths as inferred, so requiring verifiedExclusive
    /// made the previous default unreachable. Only the exact app identifier namespace in
    /// this user's Caches directory qualifies, with a live eligible target and no competing claim.
    static func disposableCache(_ path: String, app: DiskApplication, home: String) -> Bool {
        let prefix = home + "/Library/Caches/"
        guard path.hasPrefix(prefix), let target = DiskAppDataRemoval.target(path, home: home), target.fileIdentity == nil else { return false }
        let name = String(path.dropFirst(prefix.count))
        guard !name.contains("/"), AppOwner.validIdentifier(name), app.owner.identifiers.contains(name) else { return false }
        let claims = app.ownership.filter { $0.paths.contains(path) }
        return claims.contains { $0.source == "identifierConvention" || $0.confidence == .verifiedExclusive } && claims.allSatisfy {
            $0.ownerPaths == [app.owner.path] && $0.confidence != .shared && !$0.source.hasPrefix("receiptManifest")
        }
    }
}
