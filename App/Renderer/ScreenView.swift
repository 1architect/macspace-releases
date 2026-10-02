import MacSpaceSdk
import SwiftUI

/// A module's full page: header, progress and result of the last action, then the module's widgets.
/// While the page opens out of a dashboard tile (`zoom`), the widget the tile turns into and the title are shown by the zoom itself;
/// the page brings in the rest one after another.
struct ScreenView: View {
    @ObservedObject var handle: ModuleHandle
    var zoom: ScreenZoom?

    private func part(_ part: ZoomReveal.Part) -> ZoomReveal {
        ZoomReveal(part: part, progress: zoom?.progress ?? 1, reveal: zoom?.reveal ?? 1)
    }

    var body: some View {
        let heroIndex = zoom == nil ? nil : handle.screen.flatMap { ZoomMath.heroIndex(in: $0, summary: handle.summary) }
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if let progress = handle.progress { ProgressCard(progress: progress) }
                if let result = handle.lastResult { ResultBanner(result: result) { handle.dismissResult() } }
                if let screen = handle.screen {
                    ForEach(Array(screen.widgets.enumerated()), id: \.element.id) { index, widget in
                        WidgetView(widget: widget) { action, extra in
                            Task { await handle.perform(action, extraParameters: extra) }
                        }
                        .modifier(part(index == heroIndex ? .hero : .stagger(index + 1)))
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(ZoomSpace.name)) } action: { frame in
                            if index == heroIndex { zoom?.frames.hero = frame }
                        }
                    }
                } else {
                    ProgressView("Loading…").frame(maxWidth: .infinity).padding(.top, 40)
                }
            }
            .padding(20)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollEdgeEffectHidden(true, for: .top)
        .disabled(handle.isBusy && handle.progress != nil)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(handle.screen?.title ?? handle.manifest.name).font(.largeTitle.weight(.bold))
                    .modifier(part(.title))
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(ZoomSpace.name)) } action: { zoom?.frames.title = $0 }
                if let subtitle = handle.screen?.subtitle ?? Optional(handle.manifest.summary) {
                    Text(subtitle).foregroundStyle(.secondary).modifier(part(.stagger(0)))
                }
            }
            Spacer()
            if handle.isBusy { ProgressView().controlSize(.small) }
            Button { Task { await handle.refresh(reload: true) } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .disabled(handle.isBusy)
                .modifier(part(.stagger(0)))
        }
    }
}

struct ProgressCard: View {
    let progress: ActionProgress

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                if let fraction = progress.fraction { ProgressView(value: fraction) } else { ProgressView() }
                Text(progress.message).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

struct ResultBanner: View {
    let result: ActionResult
    let dismiss: () -> Void

    var body: some View {
        let severity: Banner.Severity = result.outcome == .succeeded ? .success : (result.outcome == .failed ? .critical : .warning)
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: Palette.symbol(severity)).foregroundStyle(Palette.color(severity))
            VStack(alignment: .leading, spacing: 3) {
                Text(result.message).font(.headline)
                ForEach(Array(result.details.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.callout).foregroundStyle(.secondary)
                }
                if result.restartRequired { Text("Restart the Mac for this to take effect.").font(.callout.weight(.semibold)) }
            }
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.borderless)
        }
        .padding(12)
        .background(Palette.color(severity).opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }
}
