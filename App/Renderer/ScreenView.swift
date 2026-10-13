import MacSpacePlatform
import MacSpaceSdk
import SwiftUI

/// A module's page, drawn on the tile it grew from. The title and status stay in the tile's corner (drawn by the zoom), so the page
/// has no header: it starts with the hero bar, if the module has one, then the module's widgets. The main action is pinned at the
/// bottom left and turns into the progress of whatever is running; the outcome shows as a note above it.
struct ScreenView: View {
    @ObservedObject var handle: ModuleHandle
    var tint: TileTint = .slate
    var reveal: CGFloat = 1
    @Environment(\.design) private var design

    /// The bottom-left dock is showing: the main action, the progress of an action, or its outcome.
    private var hasFooter: Bool {
        handle.screen?.primary != nil || handle.isCleaning || handle.lastResult != nil
            || !Self.banners(in: handle.screen?.widgets ?? []).isEmpty
    }

    /// What the page shows: the module's screen, or while it loads, the tile's own blocks as the hero (pulsing), which then move to
    /// the page's figures as its rows come in under them. nil while there is nothing to show yet.
    private var content: (hero: UsageBar?, widgets: [ScreenWidget], loaded: Bool)? {
        // Banners are not drawn on the page: what they say is in the main button (`ActionDock`).
        if let screen = handle.screen { return (screen.hero, Self.withoutBanners(screen.widgets), true) }
        if case let .blocks(segments)? = handle.tile?.graphic, !segments.isEmpty {
            return (UsageBar(id: "usage", title: "", segments: segments), [], false)
        }
        return nil
    }

    /// The group pages open over the module's page (`ModuleHandle.groupPath`), as the module's screen has them now, bottom first. A
    /// refresh that no longer has one (its items were freed) ends the stack there.
    private var openGroups: [Row] {
        guard let screen = handle.screen else { return [] }
        var rows: [Row] = []
        for id in handle.groupPath {
            guard let row = Self.row(id, in: screen) else { break }
            rows.append(row)
        }
        return rows
    }

    /// Every banner of a page, in page order, sections included.
    static func banners(in widgets: [ScreenWidget]) -> [Banner] {
        widgets.flatMap { widget -> [Banner] in
            switch widget {
            case let .banner(banner): return [banner]
            case let .section(section): return banners(in: section.widgets)
            default: return []
            }
        }
    }

    /// A page's widgets without its banners; a section left empty goes too.
    static func withoutBanners(_ widgets: [ScreenWidget]) -> [ScreenWidget] {
        widgets.compactMap { widget -> ScreenWidget? in
            switch widget {
            case .banner: return nil
            case var .section(section):
                section.widgets = withoutBanners(section.widgets)
                return section.widgets.isEmpty ? nil : .section(section)
            default: return widget
            }
        }
    }

    /// The group page with this id on a page: a group row (`row(_:in:)` on its widgets), or a block of its hero that lists what it
    /// is made of (`UsageSegment.group`).
    static func row(_ id: String, in screen: Screen) -> Row? {
        if let row = row(id, in: screen.widgets) { return row }
        for segment in screen.hero?.segments ?? [] {
            guard let group = segment.group else { continue }
            if group.id == id { return group }
            if let row = row(id, in: [.list(ListWidget(id: group.id, rows: group.children))]) { return row }
        }
        return nil
    }

    /// The group row with this id, wherever it is: in a list, a section, or among another group's items (a group inside a group
    /// opens too, instead of leaving the page).
    static func row(_ id: String, in widgets: [ScreenWidget]) -> Row? {
        func find(_ rows: [Row]) -> Row? {
            for row in rows {
                if row.id == id && !row.children.isEmpty { return row }
                if let found = find(row.children) { return found }
            }
            return nil
        }
        for widget in widgets {
            switch widget {
            case let .list(list): if let row = find(list.rows) { return row }
            case let .section(section): if let row = row(id, in: section.widgets) { return row }
            default: continue
            }
        }
        return nil
    }

    private var handler: ActionHandler {
        { [handle] action, extra, quiet in await handle.perform(action, extraParameters: extra, quiet: quiet) }
    }

    var body: some View {
        let groups = openGroups
        // A stack of pages: the module's page, then each group page opened over it. A new page slides in from the right over the one
        // under it, which moves aside; Back slides the top one out to the right and the page under it comes back.
        ZStack(alignment: .topLeading) {
            mainPage
                .modifier(StackedPage(covered: !groups.isEmpty))
            ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                groupPage(group)
                    .modifier(StackedPage(covered: index < groups.count - 1))
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(Theme.push, value: groups.map(\.id))
        .environment(\.openGroup, GroupOpener(module: handle.id) { [handle] id in handle.pushGroup(id) })
        .modifier(ZoomReveal(index: 1, reveal: reveal))
        .animation(Theme.layout, value: hasFooter)
        .overlay(alignment: .bottomLeading) {
            ActionDock(handle: handle)
                .padding(.leading, PageInsets.side)
                .padding(.bottom, 18)
                .modifier(ZoomReveal(index: 2, reveal: reveal))
        }
        .disabled(handle.isBusy && handle.progress != nil)
        .environment(\.colorScheme, design.colorScheme)
        .environment(\.pageGround, design.palette(tint).base)
        // A refresh that no longer has an open group (its items were freed) goes back to the page under it.
        .onChange(of: groups.count) { _, count in
            if count < handle.groupPath.count { handle.groupPath = Array(handle.groupPath.prefix(count)) }
        }
    }

    @ViewBuilder
    private var mainPage: some View {
        Group {
            if let content = self.content {
                // While the module reads the Mac again (Refresh, or after an action), only the blocks stay, pulsing: the legend and the
                // groups under them fold away and rise in again with the new figures, instead of showing figures about to change.
                let refreshing = content.loaded && handle.isRefreshing
                WidgetForm(widgets: refreshing ? [] : content.widgets, handler: handler, showsTop: content.hero != nil) {
                    if let hero = content.hero {
                        HeroBlocks(usage: hero, tint: tint, loading: !content.loaded || handle.isRefreshing)
                            .padding(.bottom, 4)
                            .textCase(nil)
                            .foregroundStyle(.primary)
                    }
                }
                .animation(Theme.layout, value: refreshing ? [] : content.widgets.map(\.id))
            } else {
                PageSkeleton()
                    .padding(.top, PageInsets.top - PageInsets.scrollTop)
                    .padding(.horizontal, PageInsets.side)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .scrollIndicators(.never)
        .modifier(PageScrollArea(hasFooter: hasFooter))
    }

    /// Every item of a group, each with its size and actions, under a header that repeats the group's count and total. A group whose
    /// page is in parts (`Selection.sections`) lists each part under a header of its own, with a box that checks the whole part.
    private func groupPage(_ group: Row) -> some View {
        let widgets: [ScreenWidget]
        if let selection = group.selection, !selection.sections.isEmpty {
            let byID = Dictionary(group.children.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            widgets = selection.sections.compactMap { section -> ScreenWidget? in
                let rows = section.rows.compactMap { byID[$0] }
                guard !rows.isEmpty else { return nil }
                return .list(ListWidget(id: "group-section:\(section.id)", title: section.title, rows: rows))
            }
        } else {
            widgets = [.list(ListWidget(id: "group-items:\(group.id)", title: [group.title, group.subtitle, group.trailing].compactMap { $0 }.joined(separator: " · "),
                                        rows: group.children))]
        }
        return WidgetForm(widgets: widgets, handler: handler, showsTop: false) { EmptyView() }
            .scrollIndicators(.never)
            .modifier(PageScrollArea(hasFooter: hasFooter))
            .environment(\.rowChoice, group.selection.map { selection in
                RowChoice(choices: Set(selection.choices.keys), checked: handle.checked(group)) { [handle] id in
                    withAnimation(Self.choiceAnimation) { handle.toggle(id, in: group) }
                }
            })
            .environment(\.sectionChoice, group.selection.flatMap { selection in
                selection.sections.isEmpty ? nil : SectionChoice(selection: selection, checked: handle.checked(group), all: handle.allChecked(group)) { [handle] id in
                    withAnimation(Self.choiceAnimation) { handle.toggleAll(id, in: group) }
                }
            })
    }

    /// A box clicked: the boxes it changes (a whole part's, from its header) and the button's title and total move together, springing
    /// as a press does. None with Reduce Motion.
    static var choiceAnimation: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : Theme.press
    }
}

extension EnvironmentValues {
    /// Where a page's scroll area starts: under the glass window's corner buttons and title, or right under a standard window's
    /// toolbar (`StandardWindowView`).
    @Entry var pageScrollTop: CGFloat = PageInsets.scrollTop
    /// The page's own color, which the glass along its edges is tinted with so it does not lighten it (`EdgeGlass`).
    @Entry var pageGround: Color?
}

/// A page with another page open over it: moved aside, faded out, and not taking clicks, until the page over it goes.
private struct StackedPage: ViewModifier {
    let covered: Bool

    func body(content: Content) -> some View {
        content
            .offset(x: covered ? -80 : 0)
            .opacity(covered ? 0 : 1)
            .allowsHitTesting(!covered)
            .accessibilityHidden(covered)
    }
}

/// Room around a page's content: the corner button at the top left, the caption and the dock at the bottom.
enum PageInsets {
    static let top: CGFloat = 70
    /// Where the corner buttons and the title end.
    static let headerBottom: CGFloat = 50
    /// Where a page's scroll area starts: clear of the title, so a section header scrolled up to it is not cut off right under it.
    static let scrollTop: CGFloat = 62
    static let side: CGFloat = 30
    /// How far a grouped form indents its section headers from the edge of its groups (to line up with the text in the rows). The page's
    /// hero sits in the first header.
    static let formHeaderIndent: CGFloat = 10
    /// The band at the bottom that belongs to the main action, when the page has one; content never shows in it.
    static let footer: CGFloat = 58
    /// Room left under a page's last row when it is scrolled to the end.
    static let fade: CGFloat = 36
}

/// A page's scroll area: below the corner buttons and the title, and above the main action when the page has one. It is cut off with
/// a plain rectangular clip.
///
/// With the temporary Page Edge Fade switch on, the page scrolls under the title and the main action and fades out as it reaches
/// them: the scroll area is masked with a gradient, clear under the title and the action and opaque between, so the content itself
/// fades (a color laid over it only looked like a band with the text showing through). A mask makes every scroll frame draw the page
/// offscreen and blend it through the mask, which is why it is only on with the switch. The system's scroll edge effect is not drawn
/// for a grouped form.
struct PageScrollArea: ViewModifier {
    let hasFooter: Bool
    @Environment(\.design) private var design
    @Environment(\.pageScrollTop) private var scrollTop

    /// How far the content takes to fade in, below the title and above the main action.
    static let fadeLength: CGFloat = 26

    func body(content: Content) -> some View {
        if design.pageEdgeFade && design.pageEdgeBlur {
            let footer = hasFooter ? PageInsets.footer : 0
            let top = max(scrollTop - (PageInsets.scrollTop - PageInsets.headerBottom), 0)
            // The content is not faded: it goes on under the title and the action, and the glass blurs it there.
            content
                .contentMargins(.top, scrollTop, for: .scrollContent)
                .contentMargins(.bottom, 0, for: .scrollContent)
                .environment(\.pageBottomRoom, footer + PageInsets.fade + 6)
                .contentMargins(.horizontal, 10, for: .scrollContent)
                .scrollEdgeEffectHidden(true, for: .all)
                .overlay(alignment: .top) { EdgeGlass(edge: .top).frame(height: top + Self.fadeLength * 1.5) }
                .overlay(alignment: .bottom) { EdgeGlass(edge: .bottom).frame(height: footer + Self.fadeLength * 1.5) }
        } else if design.pageEdgeFade {
            let footer = hasFooter ? PageInsets.footer : 0
            content
                .contentMargins(.top, scrollTop, for: .scrollContent)
                .contentMargins(.bottom, 0, for: .scrollContent)
                .environment(\.pageBottomRoom, footer + PageInsets.fade + 6)
                .contentMargins(.horizontal, 10, for: .scrollContent)
                .scrollEdgeEffectHidden(true, for: .all)
                .mask {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: max(scrollTop - (PageInsets.scrollTop - PageInsets.headerBottom), 0))
                        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: Self.fadeLength)
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: Self.fadeLength)
                        Color.clear.frame(height: max(footer - 8, 0))
                    }
                }
        } else {
            content
                .contentMargins(.top, 0, for: .scrollContent)
                .contentMargins(.bottom, 0, for: .scrollContent)
                .environment(\.pageBottomRoom, PageInsets.fade + 6)
                .contentMargins(.horizontal, 10, for: .scrollContent)
                .scrollEdgeEffectHidden(true, for: .all)
                .padding(.top, scrollTop)
                .padding(.bottom, hasFooter ? PageInsets.footer : 0)
                .clipped()
        }
    }
}

extension EnvironmentValues {
    /// Room the page leaves under its last row (`PageScrollArea`), for `PageBottomRoom`.
    @Entry var pageBottomRoom: CGFloat = 0
}

/// The room under a page's last row, so it can scroll clear of the fade and the main action. Content, not the scroll view's bottom
/// margin: macOS keeps a band over a scroll view's margin that takes the clicks, and the rows that scrolled into it, just above the
/// fade, could not be clicked. Goes last in each page's form.
struct PageBottomRoom: View {
    @Environment(\.pageBottomRoom) private var room

    var body: some View {
        Section {} footer: { Color.clear.frame(height: max(room - 20, 0)) }
    }
}

/// A band of Liquid Glass along a page's top or bottom edge, solid at the edge and fading out toward the page, so what scrolls under it
/// blurs more the closer it gets to the edge. It never takes the pointer: the page scrolls through it.
private struct EdgeGlass: View {
    let edge: VerticalEdge
    @Environment(\.pageGround) private var ground
    @Environment(\.design) private var design

    var body: some View {
        // Glass lightens a deep page: the page's own color, a little darker, tinted into it brings it back to the page's brightness
        // (measured within 3 levels). On a light page the glass adds no light and is left as it is.
        // A page that does not say its color gets black, which comes close too (within 7 levels).
        let tint = ground.map { $0.mix(with: .black, by: 0.15).opacity(0.6) } ?? .black.opacity(0.35)
        let glass: Glass = design.isLight ? .regular : .regular.tint(tint)
        Color.clear
            .glassEffect(glass, in: Rectangle())
            .mask {
                LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.45), .init(color: .clear, location: 1)],
                               startPoint: edge == .top ? .top : .bottom, endPoint: edge == .top ? .bottom : .top)
            }
            .allowsHitTesting(false)
    }
}

/// The page's hero: the tile's blocks grown large, each named, with every part listed underneath (small blocks have no room for
/// their names).
struct HeroBlocks: View {
    let usage: UsageBar
    let tint: TileTint
    /// The module is reading the Mac again: the blocks pulse, as a tile's do while it loads, and the lines under them fold away until
    /// the new figures arrive.
    var loading = false
    @Environment(\.design) private var design
    @Environment(\.openGroup) private var openGroup
    /// The block under the pointer: it darkens, and the line under the blocks names it, as on the tile.
    @State private var hovered: String?
    @State private var blocksSize = CGSize.zero

    static let gap: CGFloat = 3

    var body: some View {
        let segments = usage.segments
        let blocks = BlockLayout.blocks(segments)
        let hoveredSegment = hovered.flatMap { id in blocks.first { $0.segment.id == id }?.segment }
        VStack(alignment: .leading, spacing: 10) {
            // The blocks reach the edges of the groups below: out of the header's indent, and out by half the gap each block keeps around
            // itself. The legend stays lined up with the headers and the rows' text.
            BlocksView(segments: segments, tint: tint, hovered: hovered, gap: Self.gap, loading: loading)
                .frame(height: 150)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { blocksSize = $0 }
                .onContinuousHover { phase in
                    switch phase {
                    case let .active(location):
                        let id = BlocksView.segment(at: location, in: blocksSize, segments: segments)?.id
                        if id != hovered { hovered = id }
                    case .ended:
                        if hovered != nil { hovered = nil }
                    }
                }
                // A block that lists what it is made of opens a page of them, as a group row does: the same stack, title and Back.
                // Not while the figures are being read again.
                .onTapGesture { location in
                    guard !loading, let segment = BlocksView.segment(at: location, in: blocksSize, segments: segments),
                          let group = segment.group else { return }
                    openGroup(group.id)
                }
                .padding(.horizontal, -(PageInsets.formHeaderIndent + Self.gap / 2))
            if !loading {
                legend(segments: segments, blocks: blocks, hoveredSegment: hoveredSegment)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(Theme.layout, value: loading)
    }

    private func legend(segments: [UsageSegment], blocks: [(segment: UsageSegment, weight: Double)], hoveredSegment: UsageSegment?) -> some View {
        let palette = design.palette(tint)
        return VStack(alignment: .leading, spacing: 10) {
            // What the pointer is on, or what amber means: the same line as under the tile's blocks.
            HStack(spacing: 6) {
                if let hoveredSegment {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(BlockColor.fill(hoveredSegment, shade: BlockLayout.shade(of: hoveredSegment, in: blocks) ?? 0, tint: tint, design: design))
                        .frame(width: 9, height: 9)
                    Text("\(hoveredSegment.label) · \(ByteFormat.string(hoveredSegment.bytes))")
                } else if !segments.isEmpty {
                    Text("\(ByteFormat.string(usage.totalBytes ?? segments.reduce(0) { $0 + $1.bytes })) in total")
                    // How the total was reached, and what it leaves out.
                    InfoButton(text: usage.footnote)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(palette.soft)
            .frame(height: 14, alignment: .leading)
            .animation(Theme.hover, value: hovered)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), alignment: .leading)], alignment: .leading, spacing: 5) {
                // Every part, in the color of the block it is drawn in (the smaller ones share theirs).
                ForEach(usage.segments, id: \.id) { segment in
                    HStack(spacing: 6) {
                        // A part left out of the blocks (too small to draw) is an outline: it has no block to share a color with.
                        Group {
                            if let shade = BlockLayout.shade(of: segment, in: blocks) {
                                RoundedRectangle(cornerRadius: 2).fill(BlockColor.fill(segment, shade: shade, tint: tint, design: design))
                            } else {
                                RoundedRectangle(cornerRadius: 2).strokeBorder(design.palette(tint).soft, lineWidth: 1)
                            }
                        }
                        .frame(width: 9, height: 9)
                        Text(segment.label).font(.caption).lineLimit(1)
                        Text(ByteFormat.string(segment.bytes)).font(.caption.monospacedDigit()).foregroundStyle(design.palette(tint).soft)
                            .contentTransition(.numericText())
                    }
                }
            }
            .animation(Theme.value, value: usage.segments)
        }
    }
}

/// The page's shape while the module reads the Mac, for a page with no chart (`HeroBlocks` stands in for one with blocks): groups of
/// rows as the form will draw them, a heading over each and, in each row, a title and a switch. It stays still: the page's card
/// brightens and dims while it loads (`TileBackdrop.loading`), as a tile does. A few large grey boxes stood in for it before.
private struct PageSkeleton: View {
    /// Rows per group, and how much of a row's width each title takes.
    private static let groups: [[CGFloat]] = [[0.42], [0.55, 0.36], [0.48], [0.38, 0.5]]

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            ForEach(Array(Self.groups.enumerated()), id: \.offset) { group, rows in
                VStack(alignment: .leading, spacing: 9) {
                    // The group's heading, in the form's header indent.
                    bar(width: 120 + CGFloat(group % 2) * 40, height: 11).padding(.leading, 12)
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { index, share in
                            if index > 0 { Rectangle().fill(.primary.opacity(0.06)).frame(height: 1).padding(.horizontal, 12) }
                            GeometryReader { proxy in
                                HStack {
                                    bar(width: proxy.size.width * share, height: 11)
                                    Spacer(minLength: 12)
                                    Capsule().fill(.primary.opacity(0.1)).frame(width: 30, height: 18)
                                }
                                .padding(.horizontal, 12)
                                .frame(height: proxy.size.height)
                            }
                            .frame(height: 40)
                        }
                    }
                    .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(String(localized: "Loading"))
    }

    private func bar(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
            .fill(.primary.opacity(0.1))
            .frame(width: max(width, 0), height: height)
    }
}

/// The bottom-left corner of a page: one pill that is the main action, turns into the progress of what is running, then into its
/// outcome, and back into the action. No note of its own: the outcome is the pill's text for a moment.
private struct ActionDock: View {
    @ObservedObject var handle: ModuleHandle
    /// A notice with nothing to act on is shown for a few seconds when it appears, then the button is the page's action again.
    @State private var showsPassingNotice = false

    /// What the page has to say, from its banners: the first one.
    private var notice: Banner? { ScreenView.banners(in: handle.screen?.widgets ?? []).first }

    /// The group page on top, when it lets the user choose (`Row.selection`): its button acts on the checked rows instead of the
    /// page's main action.
    private var choosingGroup: Row? {
        guard let id = handle.groupPath.last, let screen = handle.screen, let group = ScreenView.row(id, in: screen), group.selection != nil else { return nil }
        return group
    }

    /// The selection's action for the checked rows, titled with their total, carrying their ids; nil when none is checked.
    private var choiceAction: Action? {
        guard let group = choosingGroup, let selection = group.selection else { return nil }
        let ids = handle.checked(group)
        guard !ids.isEmpty else { return nil }
        var action = selection.action
        let total = ids.compactMap { selection.choices[$0] }.reduce(0, +)
        // While the boxes are what the module suggests, the button says so ("Free recommended").
        let suggested = Set(selection.suggested).intersection(selection.choices.keys)
        let title = ids == suggested ? selection.suggestedTitle ?? selection.action.title : selection.action.title
        // Rows with no size of their own (`Selection.choices`) put none on the button.
        action.title = total > 0 ? title + " " + ByteFormat.string(total) : title
        action.parameters["ids"] = Selection.parameter(ids.sorted())
        return action
    }

    /// The page's main action, or on a page that lets the user choose, the action on the chosen rows.
    private var mainAction: Action? { choosingGroup != nil ? choiceAction : handle.screen?.primary }

    /// The outcome of an action, then its progress; then a notice: one with a fix stays until it is fixed (the fix comes before
    /// anything else), one without shows for a moment, or for good on a page with no action; then the page's main action.
    private var phase: ActionPill.Phase? {
        if let result = handle.lastResult, !result.message.isEmpty { return .done(result) }
        if handle.isCleaning { return .working(handle.progress) }
        // Reading the Mac again: the action waits for the new figures, and says so.
        if handle.isRefreshing, mainAction != nil { return .loading }
        if let notice, notice.action != nil || mainAction == nil || showsPassingNotice { return .notice(notice) }
        if let primary = mainAction { return .idle(primary) }
        return nil
    }

    var body: some View {
        Group {
            if let phase {
                ActionPill(phase: phase, dismiss: {
                    if case .notice = phase { showsPassingNotice = false } else { handle.dismissResult() }
                }) { [handle] action in
                    if let confirmation = action.confirmation, !ConfirmationAlert.ask(confirmation, destructive: action.role == .destructive) { return }
                    await handle.perform(action)
                }
                .transition(.blurReplace)
            }
        }
        // The page's width, less its margins: the pill keeps a warning on one line wherever it fits (`ActionPill`).
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, PageInsets.side)
        .animation(Theme.layout, value: phase)
        .task(id: notice.map { "\($0.title)|\($0.message ?? "")" }) {
            guard let notice, notice.action == nil, handle.screen?.primary != nil else { return }
            showsPassingNotice = true
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { showsPassingNotice = false }
        }
    }
}

/// The main action's pill. Its shape stays while its text changes, so it grows and shrinks from one state to the next; while an
/// action runs it fills from the left as the action advances, or breathes when the module gives no fraction.
private struct ActionPill: View {
    enum Phase: Equatable {
        case idle(Action)
        case working(ActionProgress?)
        /// The module is reading the Mac again; the action comes back with the new figures.
        case loading
        case done(ActionResult)
        /// One of the page's banners: its title, and its action when it has one.
        case notice(Banner)
    }

    let phase: Phase
    let dismiss: () -> Void
    let run: @MainActor (Action) async -> Void
    @Environment(\.design) private var design
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appearsActive) private var appearsActive
    @State private var hovering = false

    private var severity: Banner.Severity? {
        switch phase {
        case let .done(result): return result.outcome == .succeeded ? .success : (result.outcome == .failed ? .critical : .warning)
        case let .notice(banner): return banner.severity
        default: return nil
        }
    }

    private var text: String {
        switch phase {
        case let .idle(action): return action.title
        case let .working(progress): return progress?.message ?? String(localized: "Working…")
        case .loading: return String(localized: "Loading…")
        case let .done(result): return result.restartRequired ? String(localized: "Restart to finish") : result.message
        case let .notice(banner): return banner.title
        }
    }

    /// Everything, a failure included, is drawn in the action color: the app has no red.
    private var fill: Color { design.action }
    private var ink: Color { design.actionDeep }

    var body: some View {
        Button {
            switch phase {
            case let .idle(action): Task { @MainActor in await run(action) }
            case let .notice(banner):
                if let action = banner.action { Task { @MainActor in await run(action) } } else { dismiss() }
            case .done: dismiss()
            case .working, .loading: break
            }
        } label: {
            // Words only, no symbol. On one line wherever the page has room for it: in a pill 360 points wide, a warning such as
            // "Inteligência Visual foi reativado pelo macOS" broke onto two lines. Never cut: a message too long for the page wraps
            // in a pill of that width, which grows to hold it.
            ViewThatFits(in: .horizontal) {
                Text(text).lineLimit(1).fixedSize()
                Text(text).lineLimit(nil).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: Self.wrapWidth, alignment: .leading)
            }
            .contentTransition(.interpolate)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(ink)
            .padding(.horizontal, 15)
            .padding(.vertical, 7)
            .background { background }
            .contentShape(Self.shape)
        }
        .buttonStyle(.plain)
        .studioPickable(.mainButton, in: Self.shape)
        .onHover { hovering = $0 }
        .animation(Theme.hover, value: hovering)
        .task(id: phase) {
            // A success goes back to the action by itself; anything else stays until it is clicked.
            guard case let .done(result) = phase, result.outcome == .succeeded, !result.restartRequired else { return }
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { dismiss() }
        }
    }

    private var background: some View {
        ZStack(alignment: .leading) {
            if design.fill(.mainButton) != nil || design.shading(.mainButton) != nil {
                ShadedFill(shape: Self.shape, color: hovering && !isWorking ? lighter : fill, accent: design.actionLight,
                           fill: design.fill(.mainButton), shading: design.shading(.mainButton), light: design.isLight)
            } else {
                Self.shape.fill(hovering && !isWorking ? lighter : fill)
            }
            if isWorking {
                let progress: ActionProgress? = if case let .working(progress) = phase { progress } else { nil }
                TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || !appearsActive)) { context in
                    let wave = LoadingWave.opacity(context.date, index: 0, count: 1, loading: true, reduceMotion: reduceMotion)
                    GeometryReader { geometry in
                        if let fraction = progress?.fraction {
                            Rectangle().fill(design.actionLight)
                                .frame(width: geometry.size.width * max(0.08, min(1, fraction)))
                                .opacity(0.7 + 0.3 * wave)
                                .animation(Theme.layout, value: fraction)
                        } else {
                            Rectangle().fill(design.actionLight).opacity(0.25 + 0.6 * wave)
                        }
                    }
                }
                .clipShape(Self.shape)
            }
        }
        .modifier(PillGlass(enabled: design.glass))
    }

    /// How wide a message that does not fit on one line wraps.
    static let wrapWidth: CGFloat = 330

    /// A capsule on one line (half its height), a rounded box once the message wraps.
    static let shape = RoundedRectangle(cornerRadius: 15.5, style: .continuous)

    private var isWorking: Bool {
        switch phase {
        case .working, .loading: return true
        default: return false
        }
    }
    private var lighter: Color { design.actionLight }
}

/// The glass around the pill, when the window is glass.
private struct PillGlass: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled { content.glassEffect(.regular.interactive(), in: ActionPill.shape) } else { content }
    }
}
