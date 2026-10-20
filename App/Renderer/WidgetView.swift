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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var flipped: Set<String> = []
    @State private var previousStructure: PageCascade.Structure?

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

    /// Each item's place in the cascade, worked out once per drawing: looked up item by item, a page of a hundred rows walked its
    /// whole list for every row on every frame.
    private struct Positions {
        let index: [String: Int]
        let offset: Int
        let count: Int
        let visible: Bool

        init(_ ids: [String], offset: Int, cascadeCount: Int, visible: Bool) {
            index = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            self.offset = offset
            count = max(cascadeCount, offset + ids.count)
            self.visible = visible
        }

        func item(_ id: String) -> PageItemReveal { PageItemReveal(index: offset + (index[id] ?? 0), count: count, visible: visible) }

        func transition(_ id: String, reduceMotion: Bool) -> AnyTransition {
            PageCascade.transition(index: offset + (index[id] ?? 0), count: count, reduceMotion: reduceMotion)
        }
    }

    private func expansion(_ section: SectionWidget) -> Binding<Bool> {
        Binding(get: { section.startsCollapsed == flipped.contains(section.id) }, set: { open in
            if open == section.startsCollapsed { flipped.insert(section.id) } else { flipped.remove(section.id) }
        })
    }

    var body: some View {
        let itemIDs = Self.itemIDs(widgets)
        let structure = PageCascade.Structure(ids: itemIDs, offset: cascadeOffset, count: cascadeCount)
        let positions = Positions(itemIDs, offset: cascadeOffset, cascadeCount: cascadeCount, visible: detailsVisible)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if showsTop { top.padding(.horizontal, PageInsets.formHeaderIndent) }
                ForEach(widgets) { widget in
                    let title = Self.title(widget)
                    let rows = entries(widget)
                    VStack(alignment: .leading, spacing: 8) {
                        if let text = title.text, !text.isEmpty {
                            // The grouped-list title of macOS's System Settings, as the app's own Settings draw it (`Form`, `.grouped`):
                            // semibold, in the text's color. Module pages had grey regular titles and Settings bold ones.
                            header(text, help: title.help, part: Self.part(widget))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.primary)
                                .accessibilityAddTraits(.isHeader)
                                .padding(.horizontal, 10)
                                .geometryGroup()
                                .modifier(positions.item(widget.id + ":header"))
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
                                    // Resolve parent placement once for the whole cell, before the cascade. Text's own content
                                    // transactions must not animate/cancel its position separately from the shade and controls.
                                    .geometryGroup()
                                    .modifier(positions.item(row.id))
                                    .transition(positions.transition(row.id, reduceMotion: reduceMotion))
                            }
                        }
                    }
                    .geometryGroup()
                    .transition(positions.transition(widget.id + ":header", reduceMotion: reduceMotion))
                }
                Color.clear.frame(height: max(bottomRoom - 20, 0))
            }
            // A row removal changes later sections' positions even when no section id changed. Wait for the existing reverse
            // cascade to finish before closing the gap; one transaction owns the form's structural layout.
            .animation(PageCascade.layoutAnimation(from: previousStructure, to: structure, reduceMotion: reduceMotion), value: itemIDs)
            // Match the native grouped Form’s 20-point inset above its first section header.
            .padding(.top, 20)
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .font(.system(size: 13))
        .buttonStyle(.bordered)
        .onChange(of: structure, initial: true) { _, next in previousStructure = next }
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
            if list.rows.isEmpty, let empty = list.emptyMessage { return [Entry(list.id + ":empty", ChangingText(text: empty).foregroundStyle(.secondary))] }
            return list.rows.map { Entry($0.id, RowView(row: $0, handler: handler)) }
        case let .toggles(list): return list.rows.map { Entry($0.id, ToggleRowView(row: $0, handler: handler)) }
        case let .button(button): return [Entry(button.id, ButtonRow(button: button, handler: handler))]
        case let .text(text): return [Entry(text.id, TextWidgetView(text: text))]
        case let .steps(steps):
            return steps.steps.enumerated().map { index, step in
                Entry("\(steps.id):\(index)", HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary)
                    ChangingText(text: step)
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
    static let duration = 0.22

    struct Structure: Equatable {
        let ids: [String]
        let offset: Int
        let count: Int

        init(ids: [String], offset: Int = 0, count: Int = 0) {
            self.ids = ids
            self.offset = offset
            self.count = max(count, offset + ids.count)
        }
    }
    /// Same vertical arrival/departure as PageItemReveal, applied only to inserted/removed identities.
    static func transition(index: Int, count: Int, reduceMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) -> AnyTransition {
        let motion = reduceMotion ? AnyTransition.opacity : .opacity.combined(with: .offset(y: -14))
        return .asymmetric(
            insertion: motion.animation(.smooth(duration: duration).delay(delay(index: index, count: count, visible: true))),
            removal: motion.animation(.smooth(duration: duration).delay(delay(index: index, count: count, visible: false))))
    }

    /// Keep the departing cell's space until its last cascade finishes, then move survivors/sections together.
    static func layoutDelay(from previous: Structure?, to next: Structure) -> Double {
        guard let previous else { return 0 }
        let remaining = Set(next.ids)
        return previous.ids.enumerated().filter { !remaining.contains($0.element) }
            .map { delay(index: previous.offset + $0.offset, count: previous.count, visible: false) + duration }.max() ?? 0
    }

    static func layoutAnimation(from previous: Structure?, to next: Structure, reduceMotion: Bool) -> Animation {
        let wait = layoutDelay(from: previous, to: next)
        return (reduceMotion ? .linear(duration: 0) : Theme.layout).delay(wait)
    }

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
            .environment(\.textChangeDelay, reduceMotion ? 0 : PageCascade.delay(index: index, count: count, visible: true))
            .opacity(visible ? 1 : 0)
            .offset(y: visible || reduceMotion ? 0 : -14)
            .allowsHitTesting(visible)
            .accessibilityHidden(!visible)
            // No onAppear animation: opening and closing a tile keeps its original transition.
            .animation(reduceMotion ? nil : .smooth(duration: PageCascade.duration).delay(PageCascade.delay(index: index, count: count, visible: visible)), value: visible)
    }
}

/// A row's title with its complementary text ("12 items", "App container") right after it, the same size and greyed, on one line:
/// a row never grows taller for it.
struct TitleLine: View {
    let title: String
    let note: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            ChangingText(text: title).lineLimit(1).layoutPriority(1)
            if let note { ChangingText(text: note).foregroundStyle(.secondary).lineLimit(1) }
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

// MARK: Rows

struct BadgeView: View {
    let badge: Badge
    var wraps = false
    /// Drawn quiet whatever its tone: the row's own action flag is working or showing its result, in the action color, and two
    /// orange pills side by side, one pulsing, fought for attention (2026-10-19).
    var quiet = false
    @Environment(\.design) private var design

    /// Only a pill that asks something of the user (`Badge.Kind.action`) is drawn in the action color, with its deep form for the text.
    private var attention: Bool { !quiet && badge.kind == .action }

    /// Every other pill has the colors of the row's (i) and folder pills (`rowPill`), grey text on a faint capsule of their height, in
    /// the warning pill's font, so the facts read as one set.
    var body: some View {
        Group {
            if wraps {
                label
            } else {
                SoftFitLayout { label.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { natural = $0 } }
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { shown = $0 }
                    .mask { SoftFitMask(hidden: max(0, natural - shown)) }
            }
        }
        // A pill that wraps (`StatusFlag`'s long errors) keeps the capsule's ends: on one line it is the same 18-point pill as every
        // other, where its extra padding had made Settings' Granted and Needed taller, boxy pills (2026-10-19, issue 31).
        .background(attention ? AnyShapeStyle(design.action) : AnyShapeStyle(.primary.opacity(0.05)),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        // What the state means now: the (i) beside it says only what the item is (`InfoText`). A pill short of room says its text.
        .help(badge.help ?? (natural - shown > 0.5 ? badge.text : ""))
    }

    @State private var natural: CGFloat = 0
    @State private var shown: CGFloat = 0

    private var label: some View {
        ChangingText(text: badge.text)
            .font(.system(size: 11, weight: .semibold))
            .lineLimit(wraps ? nil : 1)
            .fixedSize(horizontal: !wraps, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, wraps ? 2 : 0)
            .frame(minHeight: 18)
            .foregroundStyle(attention ? AnyShapeStyle(design.actionDeep) : AnyShapeStyle(.secondary))
    }
}

/// A one-line pill short of room: its text stays at its full size and the pill narrows over it by any fraction of a point, its end
/// fading. Truncated instead, the text lost a whole letter at a time while the row's Free flag grew or shrank beside it, and the pill,
/// the (i) and the folder after it moved in steps, rough, as if at a low frame rate (2026-10-19).
private struct SoftFitLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let natural = subviews[0].sizeThatFits(.unspecified)
        // Never less than its first letters, as a truncated pill kept.
        let width = max(min(proposal.width ?? natural.width, natural.width), min(natural.width, 30))
        return CGSize(width: width, height: natural.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(subviews[0].sizeThatFits(.unspecified)))
    }
}

/// The end of a narrowed pill's text fades out, more the more of it is hidden: nothing at full width, so it never switches on.
private struct SoftFitMask: View {
    let hidden: CGFloat

    var body: some View {
        let strength = min(1, hidden / 12)
        HStack(spacing: 0) {
            Rectangle()
            LinearGradient(colors: [.black, .black.opacity(1 - strength)], startPoint: .leading, endPoint: .trailing).frame(width: 18)
            Rectangle().fill(.black.opacity(1 - strength)).frame(width: 4)
        }
    }
}

/// Status and error messages share the module badges' pill shape. Longer errors stay readable. A caution or critical tone is
/// something for the user to do, in the action color; any other is a plain fact.
struct StatusFlag: View {
    let text: String
    var tone: Tone = .caution

    var body: some View { BadgeView(badge: Badge(text, tone == .caution || tone == .critical ? .action : .info), wraps: true) }
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
                ChangingText(text: banner.title).fontWeight(.semibold)
                if let message = banner.message { ChangingText(text: message).font(.caption).foregroundStyle(.secondary) }
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
    private var placement: RowFlagPlacement { .for(hasTrailingFigure: row.trailing != nil) }
    @Environment(\.rowActivity) private var activity

    /// The row's action flag is in the action color now (working, or showing its result): its pills step back (`BadgeView.quiet`).
    private var flagIsActive: Bool {
        row.activity != nil || activity.rowID == row.id || activity.queued[row.id] != nil || activity.results[row.id] != nil
    }
    let handler: ActionHandler
    @Environment(\.openGroup) private var openGroup
    @Environment(\.rowChoice) private var rowChoice

    /// Drawn on the page already: a pill that comes now arrives with its motion (`RowBadges.arrives`).
    @State private var appeared = false

    var body: some View {
        Group {
            if !row.children.isEmpty { groupRow } else { itemRow }
        }
        .modifier(RowAppeared(appeared: $appeared))
    }

    /// A group: its count after the title, its total on the right, and a chevron; a click anywhere but its (i) opens the page of its
    /// items. Not a button: a button around the row would take the (i)'s click too.
    private var groupRow: some View {
        HStack(spacing: 10) {
            TitleLine(title: row.title, note: row.subtitle)
            RowBadges(badges: row.badges, gap: 10, arrives: appeared)
            InfoButton(text: row.detail)
            Spacer(minLength: 8)
            if let trailing = row.trailing { ChangingText(text: trailing, alignment: .trailing).monospacedDigit().foregroundStyle(.secondary) }
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
            // Widths are handed out in a fixed order, not the stack's even shares: the size on the right first (never wrapped), then
            // the title, then the cluster gets all the rest, the empty room after it last. With even shares the cluster was offered
            // half of what was left while room stood empty after it: its warning pill truncated to "Não…" and came back, and the size
            // wrapped, every time a figure on the row changed during a cleanup (2026-10-19).
            HStack(spacing: 10) {
                TitleLine(title: row.title, note: row.subtitle).layoutPriority(1)
                HStack(spacing: 6) {
                    RowBadges(badges: row.badges, quiet: flagIsActive, gap: 6, arrives: appeared)
                    InfoButton(text: row.detail, steps: row.steps)
                    if !row.paths.isEmpty { RevealButton(paths: row.paths) }
                    // Last in the cluster: its width changes while it works (Free, its progress, its result), and only the room
                    // after it takes that change. Before the (i) and the folder it pushed them back and forth all through a cleanup.
                    if placement == .afterTitle { RowActionFlags(row: row, handler: handler) }
                }
                // PillMorph's presented width drives this HStack every frame. A second phase spring here would interpolate the
                // same width again, making the flag and neighbouring controls wobble and repeatedly compress the preceding badge.
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let trailing = row.trailing {
                ChangingText(text: trailing, alignment: .trailing).monospacedDigit().foregroundStyle(.secondary).fixedSize()
            }
            // No figure on the right: the flag takes the right edge (`RowFlagPlacement`).
            if placement == .trailing { RowActionFlags(row: row, handler: handler) }
        }
    }
}

/// Shows a row's files in the Finder in one window: selected in their folder when they share one, else the folder that holds them
/// all (`RevealTarget`). Only those still on disk; nothing is drawn when none is left. A folder alone, named in its help tag.
struct RevealButton: View {
    let paths: [String]
    @State private var hovering = false

    /// Read again when clicked. Drawing asks only whether one is left: a row can name hundreds of folders (other accounts'
    /// temporary folders), and each of them was looked up on every redraw.
    private var existing: [URL] {
        paths.filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    var body: some View {
        let hasFiles = paths.contains { FileManager.default.fileExists(atPath: $0) }
        Group {
            if hasFiles {
                Button { RevealTarget.show(existing) } label: {
                    Image(systemName: "folder").rowPill(active: hovering)
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .help(String(localized: "Show in Finder"))
                .accessibilityLabel(String(localized: "Show in Finder"))
                .onHover { hovering = $0 }
                .animation(Theme.hover, value: hovering)
                .transition(PageCascade.transition(index: 0, count: 1))
            }
        }
        .animation(Theme.value, value: hasFiles)
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

/// A row's pills, the same in list, group and switch rows. A pill comes and goes as the row's Free flag changes (`PillMorph`):
/// its capsule widens from nothing at its place while its words roll in (`ChangingText`), and narrows away while they roll out;
/// what follows it in the row (the (i), the folder, the size) moves with its width, both ways. A slot stays in the row at no width
/// once its pill has gone, so a pill is never inserted or removed while it moves.
///
/// Built as an insertion and removal before, it went wrong both ways (2026-10-19): the page's cascade dropped it in from above while
/// the (i) jumped; then, as a transition, the (i) slid through empty room before the pill faded in, and on removal the (i) jumped to
/// its end place under a pill cut off square, because a view being removed does not animate the row around it.
struct RowBadges: View {
    let badges: [Badge]
    var quiet = false
    /// The row's spacing after a pill, which opens and closes with it.
    var gap: CGFloat
    /// The row is on the page (`RowAppeared`): a slot added from now on is a pill arriving, not one drawn with the page. Told by the
    /// row, which is always there: kept here, on a list of pills that can be empty, it never heard that it had appeared, and a row's
    /// first pill came in still (2026-10-19).
    let arrives: Bool
    /// Slots ever needed in this row: one that empties keeps its place at no width.
    @State private var slots = 0

    var body: some View {
        ForEach(0..<max(slots, badges.count), id: \.self) { index in
            RowBadgeSlot(badge: index < badges.count ? badges[index] : nil, quiet: quiet, gap: gap, arrives: arrives)
        }
        .onChange(of: badges.count, initial: true) { _, count in if count > slots { slots = count } }
    }
}

/// Whether a row has been drawn on its page yet, for its pills (`RowBadges.arrives`).
private struct RowAppeared: ViewModifier {
    @Binding var appeared: Bool

    func body(content: Content) -> some View {
        content.onAppear { appeared = true }
    }
}

/// One pill's place in a row (`RowBadges`).
private struct RowBadgeSlot: View {
    let badge: Badge?
    let quiet: Bool
    let gap: CGFloat
    /// Made after its row was drawn: its first pill arrives with the motion. The first pill of a row without one appeared still, at
    /// once (2026-10-19).
    let arrives: Bool
    /// What is drawn: the pill leaving keeps its look, with no words, until it has narrowed away.
    @State private var shown: Badge?
    /// 0 no room ... 1 the pill's own width.
    @State private var open: Double = 0
    @State private var appeared = false
    /// The pill arriving, opened once its empty capsule is in the row.
    @State private var arriving: Badge?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var animation: Animation { reduceMotion ? .easeInOut(duration: 0.2) : Theme.layout }

    var body: some View {
        PillSlotLayout(open: open) {
            if let shown {
                BadgeView(badge: shown, quiet: quiet)
                    .onAppear {
                        // Its words have been read as none: now they roll in as the capsule opens.
                        guard let badge = arriving else { return }
                        arriving = nil
                        withAnimation(animation) {
                            self.shown = badge
                            open = 1
                        }
                    }
            }
        }
        .clipShape(Capsule())
        .padding(.trailing, -gap * (1 - open))
        .onAppear {
            appeared = true
            if arrives, let badge {
                update(badge)
            } else {
                // Already there when the page is drawn: no motion, the page's own cascade shows it.
                shown = badge
                open = badge == nil ? 0 : 1
            }
        }
        .onChange(of: badge) { _, badge in if appeared { update(badge) } }
    }

    private func update(_ badge: Badge?) {
        if let badge {
            guard shown == nil else {
                // The same pill saying something else (or coming back while it left): its words change in place and its width
                // follows.
                withAnimation(animation) {
                    shown = badge
                    open = 1
                }
                return
            }
            // Arriving: an empty capsule at no width first, so the words have nothing to roll from, then both open together.
            var instant = Transaction()
            instant.disablesAnimations = true
            arriving = badge
            withTransaction(instant) { shown = Badge("", badge.kind, help: badge.help) }
        } else if let leaving = shown {
            withAnimation(animation, completionCriteria: .logicallyComplete) {
                shown = Badge("", leaving.kind, help: leaving.help)
                open = 0
            } completion: {
                if self.badge == nil { shown = nil }
            }
        }
    }
}

/// The pill at the width the row gives it (a pill short of room narrows, `SoftFitLayout`), taking `open` of that width.
private struct PillSlotLayout: Layout {
    var open: Double

    var animatableData: Double {
        get { open }
        set { open = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let pill = subviews.first else { return .zero }
        let size = pill.sizeThatFits(proposal)
        return CGSize(width: max(0, size.width * open), height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let pill = subviews.first else { return }
        pill.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(pill.sizeThatFits(proposal)))
    }
}

/// A switch row, as in Settings. It never asks and never waits: the switch moves as soon as it is flipped, then the module makes the
/// change (`LiveSwitch`).
struct ToggleRowView: View {
    let row: ToggleRow
    let handler: ActionHandler
    /// Drawn on the page already: a pill that comes now arrives with its motion (`RowBadges.arrives`).
    @State private var appeared = false

    var body: some View {
        LiveSwitch(isOn: row.isOn, apply: { value in
            let result = await handler(row.action, ["value": value ? "true" : "false"], true, row.id)
            return result.map { $0.outcome != .failed } ?? false
        }) { isOn in
            HStack(spacing: 8) {
                TitleLine(title: row.title, note: row.subtitle)
                // Pills before the (i), as in list rows.
                RowBadges(badges: row.badge.map { [$0] } ?? [], gap: 8, arrives: appeared)
                InfoButton(text: row.detail)
                Spacer(minLength: 8)
                // Never squeezed, as in list rows: without its own size it could be given no room beside a long pill and only showed
                // when the pointer redrew the row (2026-10-19).
                if let trailing = row.trailing {
                    ChangingText(text: trailing, alignment: .trailing).monospacedDigit().foregroundStyle(.secondary).fixedSize()
                }
                Toggle(row.title, isOn: isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
        }
        .disabled(!row.isEnabled)
        .modifier(RowAppeared(appeared: $appeared))
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
                        ChangingText(text: segment.label).font(.caption)
                        ChangingText(text: ByteFormat.string(segment.bytes)).font(.caption).foregroundStyle(.secondary)
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
                    ChangingText(text: bar.label).font(.callout).frame(width: 150, alignment: .leading).lineLimit(1)
                    GeometryReader { proxy in
                        Capsule().fill(Palette.color(bar.tone, design))
                            .frame(width: max(3, proxy.size.width * bar.value / maximum))
                    }
                    .frame(height: 8)
                    ChangingText(text: bar.valueLabel, alignment: .trailing).font(.caption).foregroundStyle(.secondary).frame(width: 72, alignment: .trailing)
                }
            }
        }
    }
}

struct TextWidgetView: View {
    let text: TextWidget

    var body: some View {
        switch text.style {
        case .title: ChangingText(text: text.text).font(.title2.weight(.semibold))
        case .body: ChangingText(text: text.text)
        case .caption: ChangingText(text: text.text).font(.caption).foregroundStyle(.secondary)
        }
    }
}
