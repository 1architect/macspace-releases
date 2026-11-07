import Foundation
import MacSpacePlatform
import MacSpaceSdk

extension ModuleHandle {
    var selectedAction: Action? {
        guard let group = activeSelection, let selection = group.selection else { return nil }
        let ids = checked(group)
        guard selection.bulk?.unavailableReason == nil,
              selection.includedBytes != nil || (selection.bulk.map({ $0.count > 0 }) ?? !ids.isEmpty) else { return nil }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var action = selection.action.id == CleanupBatch.actionID ? cleanupAction(ids: ids) : selection.action
        let total = (selection.includedBytes ?? 0) + (selection.bulk?.bytes ?? ids.compactMap { selection.choices[$0] }.reduce(0, +))
        // While the boxes are what the module suggests, the button says so ("Free recommended").
        let suggested = Set(selection.suggested).intersection(selection.choices.keys)
        let title = ids == suggested ? selection.suggestedTitle ?? selection.action.title : selection.action.title
        // Rows with no size of their own (`Selection.choices`) put none on the button.
        action.title = total > 0 ? title + " " + ByteFormat.string(total) : title
        if let bulk = selection.bulk {
            action.parameters["ids"] = nil; action.parameters["reviewed"] = nil; action.parameters["origins"] = nil
            action.parameters["selectionToken"] = bulk.token
            if action.confirmation != nil {
                let count = bulk.count == 1 ? String(localized: "1 selected file") : String(format: String(localized: "%lld selected files"), Int64(clamping: bulk.count))
                action.confirmation?.message += "\n\n" + count + "\n" + ByteFormat.string(bulk.bytes)
            }
        } else { action.parameters["ids"] = Selection.parameter(ids.sorted()) }
        if selection.bulk == nil, !selection.reviewed.isEmpty, let data = try? encoder.encode(selection.reviewed.filter { ids.contains($0.key) }) {
            action.parameters["reviewed"] = String(decoding: data, as: UTF8.self)
        }
        if selection.bulk == nil, !selection.origins.isEmpty, let data = try? encoder.encode(selection.origins.filter { ids.contains($0.key) }) {
            action.parameters["origins"] = String(decoding: data, as: UTF8.self)
        }
        // The checked rows that name something in the confirmation (an open app, which the action quits), in page order.
        let names = (group.selection?.sections.isEmpty == false ? group.selection!.sections.flatMap(\.rows) : group.children.map(\.id)).filter(ids.contains).compactMap { selection.noteNames[$0] }.reduce(into: [String]()) { names, name in
            if !names.contains(name) { names.append(name) }
        }
        if let note = selection.note, !names.isEmpty {
            action.confirmation?.message = String(format: note, ListFormatter.localizedString(byJoining: names))
        }
        return action
    }


    func extrasAreTrusted(_ extras: [String: String], for action: Action) -> Bool {
        guard !extras.isEmpty else { return true }
        if extras.keys.allSatisfy({ $0 == "value" }), ["true", "false"].contains(extras["value"] ?? "") {
            if !tileIsStale, tile?.switchAction == action { return true }
            func contains(_ widgets: [ScreenWidget]) -> Bool {
                widgets.contains { widget in
                    if case let .toggles(list) = widget { return list.rows.contains { $0.isEnabled && $0.action == action } }
                    if case let .section(section) = widget { return contains(section.widgets) }
                    return false
                }
            }
            return ([screen].compactMap { $0 } + Array(pages.values)).contains { contains($0.widgets) }
        }
        if let group = activeSelection, group.selection?.save == action {
            return extras.allSatisfy { key, value in
                guard let ids = try? Selection.decodeIDs(value) else { return false }
                if key == "ids" { return Set(ids) == checked(group) }
                if key == "all" { return Set(ids) == allChecked(group) }
                return false
            }
        }
        return extras.allSatisfy { action.parameters[$0.key] == $0.value }
    }

    /// Fresh module output is the only source of executable contracts.
    func trustedAction(_ requested: Action) -> Action? {
        guard state == .ready else { return nil }
        var candidates: [Action] = []

        func rows(_ values: [Row]) {
            for row in values {
                candidates += row.actions
                if let action = row.contextActions?.delete { candidates.append(GraphMenuPolicy.deletion(action, label: row.title)!) }
                if let selection = row.selection { candidates += [selection.action, selection.save].compactMap { $0 } }
                rows(row.children)
            }
        }
        func segments(_ values: [UsageSegment]) {
            for segment in values {
                if let action = GraphMenuPolicy.deletion(segment.contextActions?.delete, label: segment.label) { candidates.append(action) }
            }
            rows(values.compactMap(\.group))
        }
        if !tileIsStale {
            candidates += [tile?.switchAction, tile?.freeAction].compactMap { $0 }
            if case let .blocks(values) = tile?.graphic { segments(values) }
        }
        func widgets(_ values: [ScreenWidget]) {
            for widget in values {
                switch widget {
                case let .banner(value): if let action = value.action { candidates.append(action) }
                case let .button(value): candidates.append(value.action)
                case let .toggles(value): candidates += value.rows.filter(\.isEnabled).map(\.action)
                case let .list(value): rows(value.rows)
                case let .section(value): widgets(value.widgets)
                case let .usage(value): segments(value.segments)
                default: break
                }
            }
        }
        for value in [screen].compactMap({ $0 }) + Array(pages.values) {
            candidates += [value.primary, value.selection?.action, value.selection?.save].compactMap { $0 }
            segments(value.hero?.segments ?? [])
            widgets(value.widgets)
        }
        if let selectedAction { candidates.append(selectedAction) }
        return candidates.first { $0 == requested }
    }
}
