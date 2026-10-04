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
        handle.screen?.primary != nil || handle.progress != nil || handle.lastResult != nil
    }

    /// What the page shows: the module's screen, or while it loads, the tile's own blocks as the hero (pulsing), which then move to
    /// the page's figures as its rows come in under them. nil while there is nothing to show yet.
    private var content: (hero: UsageBar?, widgets: [ScreenWidget], loaded: Bool)? {
        if let screen = handle.screen { return (screen.hero, screen.widgets, true) }
        if case let .blocks(segments)? = handle.tile?.graphic, !segments.isEmpty {
            return (UsageBar(id: "usage", title: "", segments: segments), [], false)
        }
        return nil
    }

    /// The group row whose page is open (`ModuleHandle.openGroup`), as the module's screen has it now. nil once a refresh no longer
    /// has it.
    private var openGroup: Row? {
        guard let id = handle.openGroup, let screen = handle.screen else { return nil }
        return Self.row(id, in: screen.widgets)
    }

    static func row(_ id: String, in widgets: [ScreenWidget]) -> Row? {
        for widget in widgets {
            switch widget {
            case let .list(list): if let row = list.rows.first(where: { $0.id == id && !$0.children.isEmpty }) { return row }
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
        ZStack(alignment: .topLeading) {
            if let group = openGroup {
                // A group's page slides in from the right over the module's page, and back out to the right.
                groupPage(group)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                            removal: .move(edge: .trailing).combined(with: .opacity)))
            } else {
                mainPage
                    .transition(.asymmetric(insertion: .move(edge: .leading).combined(with: .opacity),
                                            removal: .move(edge: .leading).combined(with: .opacity)))
            }
        }
        .animation(Theme.push, value: openGroup?.id)
        .environment(\.openGroup) { [handle] id in handle.openGroup = id }
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
        // A refresh that no longer has the open group (its items were freed) goes back to the module's page.
        .onChange(of: openGroup == nil) { _, gone in if gone, handle.openGroup != nil { handle.openGroup = nil } }
    }

    @ViewBuilder
    private var mainPage: some View {
        Group {
            if let content = self.content {
                WidgetForm(widgets: content.widgets, handler: handler, showsTop: content.hero != nil) {
                    if let hero = content.hero {
                        HeroBlocks(usage: hero, tint: tint, loading: !content.loaded || handle.isRefreshing)
                            .padding(.bottom, 4)
                            .textCase(nil)
                            .foregroundStyle(.primary)
                    }
                }
                .animation(Theme.layout, value: content.widgets.map(\.id))
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

    /// Every item of a group, each with its size and actions, under a header that repeats the group's count and total.
    private func groupPage(_ group: Row) -> some View {
        let list = ListWidget(id: "group-items:\(group.id)", title: [group.title, group.subtitle, group.trailing].compactMap { $0 }.joined(separator: " · "),
                              rows: group.children)
        return WidgetForm(widgets: [.list(list)], handler: handler, showsTop: false) { EmptyView() }
            .environment(\.showsRowSubtitles, true)
            .scrollIndicators(.never)
            .modifier(PageScrollArea(hasFooter: hasFooter))
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

    /// How far the content takes to fade in, below the title and above the main action.
    static let fadeLength: CGFloat = 26

    func body(content: Content) -> some View {
        if design.pageEdgeFade {
            let footer = hasFooter ? PageInsets.footer : 0
            content
                .contentMargins(.top, PageInsets.scrollTop, for: .scrollContent)
                .contentMargins(.bottom, footer + PageInsets.fade + 6, for: .scrollContent)
                .contentMargins(.horizontal, 10, for: .scrollContent)
                .scrollEdgeEffectHidden(true, for: .all)
                .mask {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: PageInsets.headerBottom)
                        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: Self.fadeLength)
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: Self.fadeLength)
                        Color.clear.frame(height: max(footer - 8, 0))
                    }
                }
        } else {
            content
                .contentMargins(.top, 0, for: .scrollContent)
                .contentMargins(.bottom, PageInsets.fade + 6, for: .scrollContent)
                .contentMargins(.horizontal, 10, for: .scrollContent)
                .scrollEdgeEffectHidden(true, for: .all)
                .padding(.top, PageInsets.scrollTop)
                .padding(.bottom, hasFooter ? PageInsets.footer : 0)
                .clipped()
        }
    }
}

/// The page's hero: the tile's blocks grown large, each named, with every part listed underneath (small blocks have no room for
/// their names).
struct HeroBlocks: View {
    let usage: UsageBar
    let tint: TileTint
    /// The module is reading the Mac again: the blocks pulse, as a tile's do while it loads.
    var loading = false
    @Environment(\.design) private var design
    /// The block under the pointer: it darkens, and the line under the blocks names it, as on the tile.
    @State private var hovered: String?
    @State private var blocksSize = CGSize.zero

    static let gap: CGFloat = 3

    var body: some View {
        let palette = design.palette(tint)
        let segments = usage.segments
        let hoveredSegment = hovered.flatMap { id in segments.first { $0.id == id } }
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
                .padding(.horizontal, -(PageInsets.formHeaderIndent + Self.gap / 2))
            // What the pointer is on, or what amber means: the same line as under the tile's blocks.
            HStack(spacing: 6) {
                if let hoveredSegment {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(BlockColor.fill(hoveredSegment, rank: segments.firstIndex(of: hoveredSegment) ?? 0, tint: tint, design: design))
                        .frame(width: 9, height: 9)
                    Text("\(hoveredSegment.label) · \(ByteFormat.string(hoveredSegment.bytes))")
                } else if segments.contains(where: { $0.tone == .caution }) {
                    RoundedRectangle(cornerRadius: 2).fill(design.action).frame(width: 9, height: 9)
                    Text("can be freed")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(palette.soft)
            .frame(height: 14, alignment: .leading)
            .animation(Theme.hover, value: hovered)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), alignment: .leading)], alignment: .leading, spacing: 5) {
                ForEach(Array(usage.segments.enumerated()), id: \.element.id) { index, segment in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(BlockColor.fill(segment, rank: index, tint: tint, design: design)).frame(width: 9, height: 9)
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

/// Grey shapes where the page will be, while the module reads the Mac.
private struct PageSkeleton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let heights: [CGFloat] = [18, 70, 130, 90]

    var body: some View {
        // The same pulse, one shape after another, as the charts while they load; no band of light sweeping across.
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(Self.heights.enumerated()), id: \.offset) { index, height in
                    let wave = LoadingWave.opacity(context.date, index: index, count: Self.heights.count, loading: true, reduceMotion: reduceMotion)
                    RoundedRectangle(cornerRadius: index == 0 ? 9 : 14, style: .continuous)
                        .fill(.primary.opacity(0.06 + 0.08 * wave))
                        .frame(height: height)
                }
            }
        }
        .accessibilityLabel("Loading")
    }
}

/// The bottom-left corner of a page: the main action, the progress of what is running in its place, and the outcome above it.
private struct ActionDock: View {
    @ObservedObject var handle: ModuleHandle

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let result = handle.lastResult {
                ResultNote(result: result) { handle.dismissResult() }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            Group {
                if let progress = handle.progress {
                    ProgressPill(progress: progress)
                        .transition(.blurReplace)
                } else if let primary = handle.screen?.primary {
                    ActionButton(action: primary) { [handle] action, extra, quiet in await handle.perform(action, extraParameters: extra, quiet: quiet) }
                        .transition(.blurReplace)
                }
            }
        }
        .frame(maxWidth: 360, alignment: .leading)
        .animation(Theme.layout, value: handle.progress)
        .animation(Theme.layout, value: handle.lastResult)
        .animation(Theme.layout, value: handle.screen?.primary)
    }
}

private struct ProgressPill: View {
    let progress: ActionProgress
    @Environment(\.design) private var design

    var body: some View {
        // In the text's color, as the round buttons: white was lost on the paper palette.
        HStack(spacing: 8) {
            if let fraction = progress.fraction {
                ProgressView(value: fraction).progressViewStyle(.circular).controlSize(.small).tint(design.ink)
            } else {
                ProgressView().controlSize(.small).tint(design.ink)
            }
            Text(progress.message).font(.system(size: 12, weight: .medium)).lineLimit(1).contentTransition(.opacity)
        }
        .foregroundStyle(design.ink)
        .padding(.horizontal, 13)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: .capsule)
    }
}

/// What the last action did. Successes go away by themselves; anything else stays until dismissed.
private struct ResultNote: View {
    let result: ActionResult
    let dismiss: () -> Void

    var body: some View {
        let severity: Banner.Severity = result.outcome == .succeeded ? .success : (result.outcome == .failed ? .critical : .warning)
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: Palette.symbol(severity)).foregroundStyle(Palette.color(severity))
            VStack(alignment: .leading, spacing: 2) {
                Text(result.message).font(.system(size: 12, weight: .semibold))
                ForEach(Array(result.details.prefix(3).enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption).foregroundStyle(.secondary)
                }
                if result.restartRequired { Text("Restart the Mac for this to take effect.").font(.caption.weight(.semibold)) }
            }
            Spacer(minLength: 4)
            Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .task(id: result) {
            guard result.outcome == .succeeded, !result.restartRequired else { return }
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { dismiss() }
        }
    }
}
