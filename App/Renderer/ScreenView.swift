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
                .contentMargins(.top, PageInsets.top - 20, for: .scrollContent)
                .contentMargins(.bottom, PageInsets.bottom(hasFooter: hasFooter) - 10, for: .scrollContent)
                .contentMargins(.horizontal, 10, for: .scrollContent)
                .animation(Theme.layout, value: screen.widgets.map(\.id))
            } else {
                PageSkeleton()
                    .padding(.top, PageInsets.top)
                    .padding(.horizontal, PageInsets.side)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .modifier(ZoomReveal(index: 1, reveal: reveal))
        .scrollIndicators(.never)
        .scrollEdgeEffectHidden(true, for: .all)
        .mask(PageFade(hasFooter: hasFooter))
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
    /// The band at the bottom that belongs to the main action, when the page has one; content never shows in it.
    static let footer: CGFloat = 58
    /// How tall the fade is where content leaves the page.
    static let fade: CGFloat = 36

    /// Room under the content, so its end can scroll clear of the fade (and of the main action).
    static func bottom(hasFooter: Bool) -> CGFloat { (hasFooter ? footer : 0) + fade + 16 }
}

/// Content fades out under the corner buttons and at the bottom: just above the window's edge, or above the main action when the page
/// has one.
struct PageFade: View, @preconcurrency Animatable {
    /// 0 without a footer, 1 with one; animated, so the fade moves when the main action comes or goes.
    var footer: CGFloat

    init(hasFooter: Bool) { footer = hasFooter ? 1 : 0 }

    var animatableData: CGFloat {
        get { footer }
        set { footer = newValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Nothing behind the buttons and the title; content fades in just below them.
            Color.clear.frame(height: PageInsets.headerBottom)
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: PageInsets.top - PageInsets.headerBottom)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: PageInsets.fade)
            Color.clear.frame(height: PageInsets.footer * footer + 6)
        }
    }
}

/// The page's hero: the tile's blocks grown large, each named, with every part listed underneath (small blocks have no room for
/// their names).
struct HeroBlocks: View {
    let usage: UsageBar
    let tint: TileTint
    @Environment(\.design) private var design

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            BlocksView(segments: usage.segments, tint: tint)
                .frame(height: 150)
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
