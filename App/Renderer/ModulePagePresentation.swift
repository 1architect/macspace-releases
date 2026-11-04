import MacSpaceSdk

/// The same source rows drive the overview and drill-down; actions, counts and selection IDs never get copied or rewritten.
enum ModulePagePresentation {
    struct Item: Identifiable {
        let id: String
        let widgets: [ScreenWidget]
        var selectionGroup: Row?
    }

    /// Empty list/section shells do not reserve an overview pane during the first scan.
    static func hasContent(_ widgets: [ScreenWidget]) -> Bool {
        widgets.contains { widget in
            switch widget {
            case .banner: return false
            case let .list(list): return !list.rows.isEmpty || list.emptyMessage?.isEmpty == false
            case let .toggles(list): return !list.rows.isEmpty
            case let .section(section): return hasContent(section.widgets)
            default: return true
            }
        }
    }

    static func items(_ widgets: [ScreenWidget], width: Double, expandsGroups: Bool) -> [Item] {
        let widgets = widgets.enumerated().sorted { left, right in
            let a = priority(left.element), b = priority(right.element)
            return a == b ? left.offset < right.offset : a > b
        }.map(\.element)
        guard expandsGroups else { return widgets.map { Item(id: $0.id, widgets: [$0]) } }
        return widgets.flatMap { widget -> [Item] in
            switch widget {
            case let .section(section) where section.priority == .actionable:
                // The action group owns the first slot intact, including its cache-page entry.
                return [Item(id: section.id, widgets: [widget])]
            case let .section(section) where !section.isCollapsible:
                return split(section.widgets, title: section.title, help: section.subtitle, id: section.id, width: width)
            case let .list(list):
                return split([widget], title: list.title, help: nil, id: list.id, width: width)
            default: return [Item(id: widget.id, widgets: [widget])]
            }
        }
    }

    private static func priority(_ widget: ScreenWidget) -> Int {
        if case let .section(section) = widget { return (section.priority ?? .normal).rawValue }
        return ModuleContentPriority.normal.rawValue
    }

    private static func split(_ widgets: [ScreenWidget], title: String?, help: String?, id: String, width: Double) -> [Item] {
        if widgets.count == 1, case let .list(list) = widgets[0],
           list.fillsRemainingSpace == true || !list.paths.isEmpty || (help == nil && title == list.title && list.rows.allSatisfy({ $0.children.isEmpty })) {
            return [Item(id: list.id, widgets: widgets)]
        }
        // A section containing other widget types retains their original presentation and help.
        guard widgets.allSatisfy({ if case .list = $0 { return true }; return false }) else {
            return [Item(id: id, widgets: [.section(SectionWidget(id: id, title: title ?? "", subtitle: help, widgets: widgets))])]
        }
        var result: [Item] = []
        var pending: [Row] = []
        func flush() {
            guard !pending.isEmpty else { return }
            let key = "overview:\(id):\(pending[0].id)"
            let list = ListWidget(id: key, title: title, rows: pending)
            let widget: ScreenWidget = help.map {
                .section(SectionWidget(id: key, title: title ?? "", subtitle: $0, widgets: [.list(list)]))
            } ?? .list(list)
            result.append(Item(id: key, widgets: [widget]))
            pending = []
        }
        for widget in widgets {
            guard case let .list(list) = widget else { continue }
            if list.rows.isEmpty { result.append(Item(id: list.id, widgets: [widget])) }
            for row in list.rows {
                // Keep deep inventories behind a drill-down when they would overwhelm the overview.
                // Selection groups retain their dedicated page and its action/confirmation.
                let limit = width >= 420 ? 24 : 8
                let canExpand = !row.children.isEmpty && row.children.count <= limit
                    && row.selection == nil
                guard canExpand else { pending.append(row); continue }
                flush()
                result.append(Item(id: "overview:\(row.id)", widgets: groupWidgets(row), selectionGroup: row.selection == nil ? nil : row))
            }
        }
        flush()
        return result
    }

    static func groupWidgets(_ group: Row) -> [ScreenWidget] {
        if let selection = group.selection, !selection.sections.isEmpty {
            let byID = Dictionary(group.children.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            return selection.sections.compactMap { section in
                let rows = section.rows.compactMap { byID[$0] }
                guard !rows.isEmpty else { return nil }
                return .list(ListWidget(id: "group-section:\(section.id)", title: section.title, rows: rows))
            }
        }
        let title = [group.title, group.subtitle, group.trailing].compactMap { $0 }.joined(separator: " ")
        return [.section(SectionWidget(id: "group-items:\(group.id)", title: title, subtitle: group.detail,
                                      widgets: [.list(ListWidget(id: "group-items-list:\(group.id)", rows: group.children))]))]
    }
}

import SwiftUI

/// Scopes each inline group to its own choices; non-choosing groups inherit a drill-down's environment.
struct OverviewChoices: ViewModifier {
    let group: Row?
    let handle: ModuleHandle?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let group, let selection = group.selection, let handle {
            content
                .environment(\.rowChoice, RowChoice(choices: handle.choosableIDs(group), checked: handle.checked(group)) { id in
                    withAnimation(ScreenView.choiceAnimation) { handle.toggle(id, in: group) }
                })
                .environment(\.sectionChoice, SectionChoice(selection: selection, checked: handle.checked(group), all: handle.allChecked(group)) { id in
                    withAnimation(ScreenView.choiceAnimation) { handle.toggleAll(id, in: group) }
                })
        } else { content }
    }
}

struct ModuleSectionHeader: View {
    let title: String
    let help: String?
    let part: String?
    @Environment(\.sectionChoice) private var choice

    var body: some View {
        if let part, let choice, choice.hasRows(part) {
            HStack(spacing: 8) {
                HeaderCheckbox(on: choice.isOn(part), mixed: choice.isMixed(part)) { choice.toggle(part) }
                    .frame(width: 14, height: 14).accessibilityLabel(title)
                InfoTitle(title: title, info: help)
            }
        } else {
            HStack(spacing: 6) {
                InfoTitle(title: title, info: help)
                if let part, let reason = choice?.unavailableReason(part) { BadgeView(badge: Badge(reason, .info)) }
            }
        }
    }
}

/// The same native checkbox as file rows, including macOS's mixed state for partial selections.
private struct HeaderCheckbox: NSViewRepresentable {
    var on: Bool
    var mixed: Bool
    var toggle: @MainActor () -> Void
    final class Coordinator: NSObject {
        var toggle: @MainActor () -> Void
        init(_ toggle: @escaping @MainActor () -> Void) { self.toggle = toggle }
        @MainActor @objc func clicked() { toggle() }
    }
    func makeCoordinator() -> Coordinator { Coordinator(toggle) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: "", target: context.coordinator, action: #selector(Coordinator.clicked))
        button.allowsMixedState = true
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.toggle = toggle
        button.state = mixed ? .mixed : on ? .on : .off
    }
}
