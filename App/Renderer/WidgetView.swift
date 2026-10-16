import AppKit
import MacSpaceSdk
import MacSpacePlatform
import SwiftUI

/// The module's grouped rows. Each row draws its own shade and separator, so both leave with
/// its text during a cascade. A native Form draws those backgrounds outside the row's animation.
struct WidgetForm<Top: View>: View {
    let widgets: [ScreenWidget]
    let handler: ActionHandler
    var showsTop = true
    var detailsVisible = true
    var cascadeOffset = 0
    @ViewBuilder var top: Top
    @Environment(\.sectionChoice) private var sectionChoice
    @Environment(\.pageCascadeCount) private var cascadeCount
    @Environment(\.pageBottomRoom) private var bottomRoom
    @State private var flipped: Set<String> = []

    static func itemIDs(_ widgets: [ScreenWidget]) -> [String] {
        widgets.flatMap { widget -> [String] in
            let header = [widget.id + ":header"]
            switch widget {
            case let .section(section):
                return header + (section.isCollapsible ? [section.id + ":disclosure"] : []) + itemIDs(section.widgets)
            case let .list(list): return header + (list.rows.isEmpty ? [list.id + ":empty"] : list.rows.map(\.id))
            case let .toggles(list): return header + list.rows.map(\.id)
            case let .steps(steps): return header + steps.steps.indices.map { "\(steps.id):\($0)" }
            default: return header + [widget.id]
            }
        }
    }

    private func item(_ id: String) -> PageItemReveal {
        let ids = Self.itemIDs(widgets)
        return PageItemReveal(index: cascadeOffset + (ids.firstIndex(of: id) ?? 0),
                              count: max(cascadeCount, cascadeOffset + ids.count), visible: detailsVisible)
    }

    private func expansion(_ section: SectionWidget) -> Binding<Bool> {
        Binding(get: { section.startsCollapsed == flipped.contains(section.id) }, set: { open in
            if open == section.startsCollapsed { flipped.insert(section.id) } else { flipped.remove(section.id) }
        })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if showsTop { top.padding(.horizontal, PageInsets.formHeaderIndent) }
                ForEach(widgets) { widget in
                    let title = Self.title(widget)
                    let rows = entries(widget)
                    VStack(alignment: .leading, spacing: 8) {
                        if let text = title.text, !text.isEmpty {
                            header(text, help: title.help, part: Self.part(widget))
                                .foregroundStyle(.secondary)
                                .accessibilityAddTraits(.isHeader)
                                .padding(.horizontal, 10)
                                .modifier(item(widget.id + ":header"))
                        }
                        VStack(spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                                row.view
                                    .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 10)
                                    .background {
                                        UnevenRoundedRectangle(topLeadingRadius: index == 0 ? 10 : 0,
                                                               bottomLeadingRadius: index == rows.count - 1 ? 10 : 0,
                                                               bottomTrailingRadius: index == rows.count - 1 ? 10 : 0,
                                                               topTrailingRadius: index == 0 ? 10 : 0)
                                            .fill(.primary.opacity(0.045))
                                    }
                                    .overlay(alignment: .top) {
                                        if index > 0 {
                                            Rectangle().fill(.primary.opacity(0.07)).frame(height: 0.5).padding(.horizontal, 10)
                                        }
                                    }
                                    .modifier(item(row.id))
                            }
                        }
                    }
                }
                Color.clear.frame(height: max(bottomRoom - 20, 0))
            }
            // Match the native grouped Form’s 20-point inset above its first section header.
            .padding(.top, 20)
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .font(.system(size: 13))
        .buttonStyle(.bordered)
    }

    private struct Entry: Identifiable {
        let id: String
        let view: AnyView
        init<V: View>(_ id: String, _ view: V) { self.id = id; self.view = AnyView(view) }
    }

    private func entries(_ widget: ScreenWidget) -> [Entry] {
        switch widget {
        case let .banner(banner): return [Entry(banner.id, BannerRow(banner: banner, handler: handler))]
        case let .usage(usage): return [Entry(usage.id, UsageBarView(usage: usage))]
        case let .chart(chart): return [Entry(chart.id, BarChartView(chart: chart))]
        case let .list(list):
            if list.rows.isEmpty, let empty = list.emptyMessage { return [Entry(list.id + ":empty", Text(empty).foregroundStyle(.secondary))] }
            return list.rows.map { Entry($0.id, RowView(row: $0, handler: handler)) }
        case let .toggles(list): return list.rows.map { Entry($0.id, ToggleRowView(row: $0, handler: handler)) }
        case let .button(button): return [Entry(button.id, ButtonRow(button: button, handler: handler))]
        case let .text(text): return [Entry(text.id, TextWidgetView(text: text))]
        case let .steps(steps):
            return steps.steps.enumerated().map { index, step in
                Entry("\(steps.id):\(index)", HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary)
                    Text(step)
                })
            }
        case let .section(section):
            guard section.isCollapsible else { return section.widgets.flatMap(entries) }
            let binding = expansion(section)
            let disclosure = Entry(section.id + ":disclosure", HStack(spacing: 8) {
                Button { withAnimation(Theme.layout) { binding.wrappedValue.toggle() } } label: {
                    Image(systemName: binding.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                    Text(section.title)
                }.buttonStyle(.plain)
                InfoButton(text: section.subtitle)
            })
            return [disclosure] + (binding.wrappedValue ? section.widgets.flatMap(entries) : [])
        }
    }

    private static func title(_ widget: ScreenWidget) -> (text: String?, help: String?) {
        switch widget {
        case let .section(section): return section.isCollapsible ? (nil, nil) : (section.title, section.subtitle)
        case let .list(list): return (list.title, nil)
        case let .toggles(list): return (list.title, list.footnote)
        case let .usage(usage): return (usage.title, usage.footnote)
        case let .chart(chart): return (chart.title, nil)
        case let .steps(steps): return (steps.title, nil)
        default: return (nil, nil)
        }
    }

    @ViewBuilder
    private func header(_ title: String, help: String?, part: String?) -> some View {
        if let part, let choice = sectionChoice, choice.hasRows(part) {
            HStack(spacing: 8) {
                Toggle(title, isOn: Binding(get: { choice.isOn(part) }, set: { _ in choice.toggle(part) }))
                    .toggleStyle(.checkbox).labelsHidden()
                InfoTitle(title: title, info: help)
            }
        } else { InfoTitle(title: title, info: help) }
    }

    private static func part(_ widget: ScreenWidget) -> String? {
        guard case let .list(list) = widget, list.id.hasPrefix(sectionPrefix) else { return nil }
        return String(list.id.dropFirst(sectionPrefix.count))
    }
    static var sectionPrefix: String { "group-section:" }
}

/// Shared ordering for the legend, headers and rows; departure runs from the bottom up.
enum PageCascade {
    static func delay(index: Int, count: Int, visible: Bool) -> Double {
        let last = max(count - 1, 0)
        let position = min(max(index, 0), last)
        let step = min(0.035, 0.6 / Double(max(last, 1)))
        return Double(visible ? position : last - position) * step
    }
}

struct PageItemReveal: ViewModifier {
    let index: Int
    var count = 1
    var visible = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible || reduceMotion ? 0 : -14)
            .allowsHitTesting(visible)
            .accessibilityHidden(!visible)
            // No onAppear animation: opening and closing a tile keeps its original transition.
            .animation(reduceMotion ? nil : .smooth(duration: 0.22).delay(PageCascade.delay(index: index, count: count, visible: visible)), value: visible)
    }
}

/// A row's title with its complementary text ("12 items", "App container") right after it, the same size and greyed, on one line:
/// a row never grows taller for it.
struct TitleLine: View {
    let title: String
    let note: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).lineLimit(1).layoutPriority(1)
            if let note { Text(note).foregroundStyle(.secondary).lineLimit(1) }
        }
    }
}

extension EnvironmentValues {
    /// Opens the page of a group row (`Row.children`), by its id.
    @Entry var openGroup = GroupOpener(module: nil) { _ in }
    /// On the page of a group that lets the user choose (`Row.selection`): which rows have a box and which are checked.
    @Entry var rowChoice: RowChoice? = nil
    /// On a choosing page in parts (`Selection.sections`): the header boxes.
    @Entry var sectionChoice: SectionChoice? = nil
}

/// Opens a group's page. Equal for the same module: a bare closure is new at every update of the page, which redrew every row that
/// reads it.
struct GroupOpener: Equatable {
    let module: String?
    let open: @MainActor (String) -> Void

    @MainActor func callAsFunction(_ id: String) { open(id) }

    static func == (lhs: GroupOpener, rhs: GroupOpener) -> Bool { lhs.module == rhs.module }
}

/// The header boxes of a choosing page in parts: a part's box is on when the user turned it on (new rows then join checked), or when
/// every row of it that can be chosen is checked.
struct SectionChoice {
    let selection: Selection
    let checked: Set<String>
    let all: Set<String>
    let toggle: @MainActor (String) -> Void

    private func choosable(_ part: String) -> Set<String> {
        Set(selection.sections.first { $0.id == part }?.rows ?? []).intersection(selection.choices.keys)
    }

    /// Every part with rows has a box, even when none of them can be chosen now (all their apps are open): turned on, it is kept, and
    /// its rows are checked as soon as they can be.
    func hasRows(_ part: String) -> Bool { !(selection.sections.first { $0.id == part }?.rows ?? []).isEmpty }

    func isOn(_ part: String) -> Bool {
        let rows = choosable(part)
        return all.contains(part) || (!rows.isEmpty && rows.isSubset(of: checked))
    }
}

/// The boxes of a group page that lets the user choose (`Row.selection`).
struct RowChoice {
    let choices: Set<String>
    let checked: Set<String>
    let toggle: @MainActor (String) -> Void
}

/// Joins the parts of a description into one text, a paragraph each (`InfoButton`).
enum Tooltip {
    static func join(_ parts: String?...) -> String? {
        let text = parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        return text.isEmpty ? nil : text
    }
}

// MARK: Rows

struct BadgeView: View {
    let badge: Badge
    var wraps = false
    @Environment(\.design) private var design

    /// What needs the user is drawn in the action color, with its deep form for the text.
    private var attention: Bool { badge.tone == .caution || badge.tone == .critical }

    /// Every other pill has the colors of the row's (i) and folder pills (`rowPill`), grey text on a faint capsule of their height, in
    /// the warning pill's font, so the facts read as one set.
    var body: some View {
        Text(badge.text)
            .font(.system(size: 11, weight: .semibold))
            .lineLimit(wraps ? nil : 1)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, wraps ? 3 : 0)
            .frame(minHeight: 18)
            .foregroundStyle(attention ? AnyShapeStyle(design.actionDeep) : AnyShapeStyle(.secondary))
            .background(attention ? AnyShapeStyle(design.action) : AnyShapeStyle(.primary.opacity(0.05)), in: Capsule())
    }
}

/// Status and error messages share the module badges' pill shape. Longer errors stay readable.
struct StatusFlag: View {
    let text: String
    var tone: Tone = .caution

    var body: some View { BadgeView(badge: Badge(text, tone: tone), wraps: true) }
}

/// A notice: icon, title and action. Its message is what the notice says, so it stays visible.
struct BannerRow: View {
    let banner: Banner
    let handler: ActionHandler
    @Environment(\.design) private var design

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: Palette.symbol(banner.severity)).foregroundStyle(Palette.color(banner.severity, design))
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.title).fontWeight(.semibold)
                if let message = banner.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            // The button keeps its title on one line; the text beside it wraps instead.
            if let action = banner.action { ActionButton(action: action, compact: true, handler: handler).fixedSize() }
        }
    }
}

/// A list row: title and its note, its (i), badge, value and actions. Its detail and steps open from the (i), which only a row with
/// something to say has. Rows are drawn without
/// the module's symbols (`Row.symbol`): text alone, as Settings lists things.
struct RowView: View {
    let row: Row
    let handler: ActionHandler
    @Environment(\.openGroup) private var openGroup
    @Environment(\.rowChoice) private var rowChoice

    var body: some View {
        if !row.children.isEmpty { groupRow } else { itemRow }
    }

    /// A group: its count after the title, its total on the right, and a chevron; a click anywhere but its (i) opens the page of its
    /// items. Not a button: a button around the row would take the (i)'s click too.
    private var groupRow: some View {
        HStack(spacing: 10) {
            TitleLine(title: row.title, note: row.subtitle)
            ForEach(Array(row.badges.enumerated()), id: \.offset) { _, badge in BadgeView(badge: badge) }
            InfoButton(text: row.detail)
            Spacer(minLength: 8)
            if let trailing = row.trailing { Text(trailing).monospacedDigit().foregroundStyle(.secondary) }
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .onTapGesture { openGroup(row.id) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { openGroup(row.id) }
    }

    private var itemRow: some View {
        HStack(spacing: 10) {
            // On a page that lets the user choose, a box first; the row's title is its label.
            if let choice = rowChoice, choice.choices.contains(row.id) {
                Toggle(row.title, isOn: Binding(get: { choice.checked.contains(row.id) }, set: { _ in choice.toggle(row.id) }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
            } else if rowChoice != nil {
                // A row that cannot be chosen now (its app is open): a dimmed box keeps the titles in line, and its pill says why.
                Toggle(row.title, isOn: .constant(false))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(true)
            }
            // A count after the title; the row's facts as pills right after it; then its (i) and where its files are, close together.
            TitleLine(title: row.title, note: row.subtitle)
            HStack(spacing: 6) {
                ForEach(Array(row.badges.enumerated()), id: \.offset) { _, badge in BadgeView(badge: badge) }
                InfoButton(text: row.detail, steps: row.steps)
                if !row.paths.isEmpty { RevealButton(paths: row.paths) }
            }
            Spacer(minLength: 8)
            if let trailing = row.trailing { Text(trailing).monospacedDigit().foregroundStyle(.secondary) }
            ForEach(Array(row.actions.enumerated()), id: \.offset) { _, action in
                ActionButton(action: action, compact: true, handler: handler)
            }
        }
    }
}

/// Shows a row's files in the Finder in one window: selected in their folder when they share one, else the folder that holds them
/// all (`RevealTarget`). Only those still on disk; nothing is drawn when none is left. A folder alone, named in its help tag.
struct RevealButton: View {
    let paths: [String]
    @State private var hovering = false

    private var existing: [URL] {
        paths.filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    var body: some View {
        if !existing.isEmpty {
            Button { RevealTarget.show(existing) } label: {
                Image(systemName: "folder").rowPill(active: hovering)
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .help(String(localized: "Show in Finder"))
            .accessibilityLabel(String(localized: "Show in Finder"))
            .onHover { hovering = $0 }
            .animation(Theme.hover, value: hovering)
        }
    }
}

/// Where Show in Finder goes. The Finder opens a window per folder for the files it is asked to select: a row whose files lie in
/// many folders (the temporary folders of every account under /private/var/folders) opened dozens of windows.
enum RevealTarget: Equatable {
    /// Files in one folder (or in a few with nothing but the root in common), selected there.
    case select([URL])
    /// Files in many folders: the deepest folder that holds them all, opened; or one hidden folder, opened.
    case open(URL)

    static func of(_ urls: [URL]) -> RevealTarget? {
        let urls = urls.map(\.standardizedFileURL)
        guard let first = urls.first else { return nil }
        // One hidden folder (the Trash, ~/.Trash) is opened: selected in its parent, the Finder showed a window where it is not drawn.
        if urls.count == 1, first.lastPathComponent.hasPrefix("."), (try? first.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            return .open(first)
        }
        let parents = Set(urls.map { $0.deletingLastPathComponent().path })
        if parents.count == 1 { return .select(urls) }
        var common = first.deletingLastPathComponent().pathComponents
        for url in urls.dropFirst() {
            let components = url.deletingLastPathComponent().pathComponents
            common = Array(zip(common, components).prefix { $0 == $1 }.map(\.0))
        }
        // Only the disk's root in common (Homebrew in /opt/homebrew and /usr/local): a window on the root shows none of them, so a few
        // places are each shown in their own window.
        if common.count <= 1 && parents.count <= 3 { return .select(urls) }
        return .open(URL(fileURLWithPath: NSString.path(withComponents: common.isEmpty ? ["/"] : common), isDirectory: true))
    }

    @MainActor
    static func show(_ urls: [URL]) {
        switch of(urls) {
        case let .select(files)?: NSWorkspace.shared.activateFileViewerSelecting(files)
        case let .open(folder)?: NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
        case nil: break
        }
    }
}

/// A switch row, as in Settings. It never asks and never waits: the switch moves as soon as it is flipped, then the module makes the
/// change (`LiveSwitch`).
struct ToggleRowView: View {
    let row: ToggleRow
    let handler: ActionHandler

    var body: some View {
        LiveSwitch(isOn: row.isOn, apply: { value in
            let result = await handler(row.action, ["value": value ? "true" : "false"], true)
            return result.map { $0.outcome != .failed } ?? false
        }) { isOn in
            HStack(spacing: 8) {
                Text(row.title)
                InfoButton(text: Tooltip.join(row.subtitle, row.detail))
                if let badge = row.badge { BadgeView(badge: badge) }
                Spacer(minLength: 8)
                Toggle(row.title, isOn: isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
        }
        .disabled(!row.isEnabled)
    }
}

/// A switch that moves as soon as it is flipped, then has the change made by `apply` (true when it was made). Flipped again while a
/// change runs, it moves at once too, and the latest position is applied as soon as the running change ends. If a change fails, the
/// switch moves back to what the Mac really has; the module's own reading (`isOn`) takes over once nothing runs.
struct LiveSwitch<Content: View>: View {
    let isOn: Bool
    let apply: @MainActor (Bool) async -> Bool
    @ViewBuilder let content: (Binding<Bool>) -> Content
    /// What the switch shows ahead of the module's answer.
    @State private var shown: Bool?
    @State private var running = false
    /// The position chosen while a change was running, applied next.
    @State private var queued: Bool?

    var body: some View {
        content(Binding(get: { shown ?? isOn }, set: flip))
            .onChange(of: isOn) { _, _ in if !running { shown = nil } }
    }

    private func flip(to value: Bool) {
        guard value != (shown ?? isOn) else { return }
        withAnimation(Theme.toggle) { shown = value }
        if running { queued = value } else { run(value) }
    }

    private func run(_ value: Bool) {
        running = true
        Task { @MainActor in
            let applied = await apply(value)
            // Where the Mac is now: the new position, or, after a failure, the one before it.
            let actual = applied ? value : !value
            if let next = queued {
                queued = nil
                if next != actual { return run(next) }
            }
            running = false
            // Done: the module's own reading takes over. Failed: back to where the Mac is.
            withAnimation(Theme.toggle) { shown = applied ? nil : actual }
            if !applied {
                try? await Task.sleep(for: .milliseconds(400))
                if !running { shown = nil }
            }
        }
    }
}

/// A button on its own: the row names the action, the button on the right says the verb; its footnote is behind the (i).
struct ButtonRow: View {
    let button: ButtonWidget
    let handler: ActionHandler

    var body: some View {
        HStack(spacing: 10) {
            Text(button.action.title).lineLimit(1)
            InfoButton(text: button.footnote)
            Spacer(minLength: 8)
            ActionButton(action: Action(id: button.action.id, title: verb, role: button.action.role, parameters: button.action.parameters,
                                        confirmation: button.action.confirmation, requires: button.action.requires),
                         compact: true, handler: handler)
        }
    }

    private var verb: String {
        button.action.title.split(separator: " ").first.map(String.init) ?? button.action.title
    }
}

struct UsageBarView: View {
    let usage: UsageBar
    @Environment(\.design) private var design

    private var total: Double {
        Double(usage.totalBytes ?? usage.segments.reduce(0) { $0 + $1.bytes })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { proxy in
                HStack(spacing: 1) {
                    ForEach(usage.segments) { segment in
                        Rectangle()
                            .fill(Palette.color(segment.tone, design))
                            .frame(width: total > 0 ? max(2, proxy.size.width * Double(segment.bytes) / total) : 0)
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: proxy.size.width, alignment: .leading)
                .background(.primary.opacity(0.14))
                .clipShape(Capsule())
            }
            .frame(height: 14)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(usage.segments) { segment in
                    HStack(spacing: 6) {
                        Circle().fill(Palette.color(segment.tone, design)).frame(width: 8, height: 8)
                        Text(segment.label).font(.caption)
                        Text(ByteFormat.string(segment.bytes)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct BarChartView: View {
    let chart: BarChart
    @Environment(\.design) private var design

    var body: some View {
        let maximum = max(chart.bars.map(\.value).max() ?? 0, .leastNonzeroMagnitude)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(chart.bars) { bar in
                HStack(spacing: 10) {
                    Text(bar.label).font(.callout).frame(width: 150, alignment: .leading).lineLimit(1)
                    GeometryReader { proxy in
                        Capsule().fill(Palette.color(bar.tone, design))
                            .frame(width: max(3, proxy.size.width * bar.value / maximum))
                    }
                    .frame(height: 8)
                    Text(bar.valueLabel).font(.caption).foregroundStyle(.secondary).frame(width: 72, alignment: .trailing)
                }
            }
        }
    }
}

struct TextWidgetView: View {
    let text: TextWidget

    var body: some View {
        switch text.style {
        case .title: Text(text.text).font(.title2.weight(.semibold))
        case .body: Text(text.text)
        case .caption: Text(text.text).font(.caption).foregroundStyle(.secondary)
        }
    }
}
