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

    var body: some View {
        Group {
            if let screen = handle.screen {
                WidgetForm(widgets: screen.widgets, handler: { action, extra in Task { await handle.perform(action, extraParameters: extra) } },
                           showsTop: screen.hero != nil) {
                    if let hero = screen.hero {
                        HeroBlocks(usage: hero, tint: tint)
                            .padding(.bottom, 4)
                            .textCase(nil)
                            .foregroundStyle(.primary)
                    }
                }
                .animation(Theme.layout, value: screen.widgets.map(\.id))
            } else {
                PageSkeleton()
                    .padding(.top, PageInsets.top - PageInsets.headerBottom)
                    .padding(.horizontal, PageInsets.side)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .modifier(ZoomReveal(index: 1, reveal: reveal))
        .scrollIndicators(.never)
        .modifier(PageScrollArea(hasFooter: hasFooter))
        .animation(Theme.layout, value: hasFooter)
        .overlay(alignment: .bottomLeading) {
            ActionDock(handle: handle)
                .padding(.leading, PageInsets.side)
                .padding(.bottom, 18)
                .modifier(ZoomReveal(index: 2, reveal: reveal))
        }
        .disabled(handle.isBusy && handle.progress != nil)
        .environment(\.colorScheme, design.colorScheme)
    }
}

/// Room around a page's content: the corner button at the top left, the caption and the dock at the bottom.
enum PageInsets {
    static let top: CGFloat = 70
    /// Where the corner buttons and the title end.
    static let headerBottom: CGFloat = 50
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
/// a plain rectangular clip. A gradient mask used to fade the content out at both ends, but it made every scroll frame draw the whole
/// page offscreen and blend it through the mask. The temporary Page Edge Fade switch turns on the system's own scroll edge fade instead.
struct PageScrollArea: ViewModifier {
    let hasFooter: Bool
    @Environment(\.design) private var design

    func body(content: Content) -> some View {
        content
            .contentMargins(.top, max(PageInsets.top - 20 - PageInsets.headerBottom, 0), for: .scrollContent)
            .contentMargins(.bottom, PageInsets.fade + 6, for: .scrollContent)
            .contentMargins(.horizontal, 10, for: .scrollContent)
            .scrollEdgeEffectStyle(.soft, for: .all)
            .scrollEdgeEffectHidden(!design.pageEdgeFade, for: .all)
            .padding(.top, PageInsets.headerBottom)
            .padding(.bottom, hasFooter ? PageInsets.footer : 0)
            .clipped()
    }
}

/// The page's hero: the tile's blocks grown large, each named, with every part listed underneath (small blocks have no room for
/// their names).
struct HeroBlocks: View {
    let usage: UsageBar
    let tint: TileTint
    @Environment(\.design) private var design

    static let gap: CGFloat = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The blocks reach the edges of the groups below: out of the header's indent, and out by half the gap each block keeps around
            // itself. The legend stays lined up with the headers and the rows' text.
            GlassGroup { BlocksView(segments: usage.segments, tint: tint, gap: Self.gap) }
                .frame(height: 150)
                .padding(.horizontal, -(PageInsets.formHeaderIndent + Self.gap / 2))
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
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Capsule().fill(.primary.opacity(0.14)).frame(height: 18)
            ForEach([70.0, 130.0, 90.0], id: \.self) { height in
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.primary.opacity(0.09)).frame(height: height)
            }
        }
        .overlay { Shimmer().clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous)) }
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
                    ActionButton(action: primary) { action, extra in Task { await handle.perform(action, extraParameters: extra) } }
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

    var body: some View {
        HStack(spacing: 8) {
            if let fraction = progress.fraction {
                ProgressView(value: fraction).progressViewStyle(.circular).controlSize(.small).tint(.white)
            } else {
                ProgressView().controlSize(.small).tint(.white)
            }
            Text(progress.message).font(.system(size: 12, weight: .medium)).lineLimit(1).contentTransition(.opacity)
        }
        .foregroundStyle(.white)
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
