import Foundation
import MacSpaceSdk

extension ModuleHandle {
    func cleanupIsSelected(_ target: CleanupTarget, preferences: [String: Bool]) -> Bool {
        if !target.remembersSelection, let choice = transientCleanupChoices[target.id] {
            if choice.defaultSelected == target.defaultSelected { return choice.selected }
            transientCleanupChoices[target.id] = nil
        }
        return target.isSelected(preferences)
    }

    func cleanupSelection(_ targets: [CleanupTarget]) -> Selection? {
        let available = targets.filter(\.available)
        guard !available.isEmpty else { return nil }
        let preferences = settings.cleanupChoices(module: id)
        return Selection(action: Action(id: CleanupBatch.actionID, title: String(localized: "Free selected"), role: .prominent,
            workingTitle: String(localized: "Freeing space")),
            choices: Dictionary(available.map { ($0.id, $0.bytes) }, uniquingKeysWith: { first, _ in first }),
            checked: available.filter { cleanupIsSelected($0, preferences: preferences) }.map(\.id),
            scope: "cleanup:" + id, partial: true, persistenceKey: "cleanup")
    }

    func cleanupTargets(in rows: [Row]) -> [CleanupTarget] {
        Screen(title: "", widgets: [.list(ListWidget(id: "cleanup", rows: rows))]).cleanupTargets
    }

    var currentCleanupTargets: [CleanupTarget] {
        let sources = [screen].compactMap { $0 } + groupPath.compactMap { pages[$0] }
        var seen = Set<String>()
        return sources.flatMap(\.cleanupTargets).filter { seen.insert($0.id).inserted }
    }

    func cleanupAction(ids: Set<String>) -> Action {
        let targets = currentCleanupTargets.filter { ids.contains($0.id) && $0.available }.sorted { $0.id < $1.id }
        var required: [Permission] = []
        for permission in targets.flatMap(\.action.requires) where !required.contains(permission) { required.append(permission) }
        let message = targets.map { target in
            let confirmation = target.action.confirmation
            return target.title + (confirmation.map { "\n" + $0.title + ($0.message.isEmpty ? "" : "\n" + $0.message) } ?? "")
        }.joined(separator: "\n\n")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return Action(id: CleanupBatch.actionID, title: String(localized: "Free selected"), role: .prominent,
            parameters: ["targets": String(decoding: (try? encoder.encode(targets)) ?? Data(), as: UTF8.self)],
            confirmation: Confirmation(title: String(localized: "Free the selected items?"), message: message, confirmTitle: String(localized: "Free")),
            requires: required, workingTitle: String(localized: "Freeing space"))
    }
}
