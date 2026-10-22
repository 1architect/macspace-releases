// Development builds only (`MACSPACE_DEV`, set by Scripts/Assemble.sh for a -dev build): a release has no design tools.
#if MACSPACE_DEV
import AppKit
import SwiftUI

/// Temporary: the Chart Motion window (Design menu, ⌥⌘G). How the charts' blocks open while their figures are read, close on Refresh
/// and drain as space is freed (`ChartMotion`), applied as they change. Replay plays a pretend reading on the charts on screen; Copy
/// JSON hands the settled values over.
public struct ChartMotionView: View {
    @ObservedObject private var settings = DesignSettings.shared
    /// How long Replay's pretend reading takes.
    @State private var replaySeconds = 3.0

    public static let windowID = "chartMotion"

    public init() {}

    public var body: some View {
        Form {
            Section {
                slider("Speed", value: $settings.motionTuning.speed, in: 0.25...4, step: 0.05, format: "×%.2f")
                slider("Reading ahead", value: $settings.motionTuning.ahead, in: 1...5, step: 0.05, format: "%.2f")
            } header: {
                Text("Speed")
            } footer: {
                Text("Speed runs the whole motion faster or slower: the reading drawn, the blocks' spring, the closing and the draining. "
                     + "Reading ahead draws the reading further on than it is (1 is as it is), so the first blocks come sooner; it still ends with the reading.")
                    .foregroundStyle(.secondary)
            }
            Section {
                slider("Smoothing", value: $settings.motionTuning.smoothing, in: 0.02...1, step: 0.01, format: "%.2f s")
                slider("Creep", value: $settings.motionTuning.creep, in: 0...0.5, step: 0.01, format: "%.2f")
                slider("Creep time", value: $settings.motionTuning.creepTime, in: 0.2...8, step: 0.1, format: "%.1f s")
            } header: {
                Text("Reading")
            } footer: {
                Text("How closely the reading drawn follows the real one, and how far, how slowly, it creeps on while the module says nothing new.")
                    .foregroundStyle(.secondary)
            }
            Section {
                slider("Overlap", value: $settings.motionTuning.overlap, in: 0...0.5, step: 0.01, format: "%.2f")
                slider("Curve x1", value: $settings.motionTuning.curveX1, in: 0...1, step: 0.01, format: "%.2f")
                slider("Curve y1", value: $settings.motionTuning.curveY1, in: -0.5...1.5, step: 0.01, format: "%.2f")
                slider("Curve x2", value: $settings.motionTuning.curveX2, in: 0...1, step: 0.01, format: "%.2f")
                slider("Curve y2", value: $settings.motionTuning.curveY2, in: -0.5...1.5, step: 0.01, format: "%.2f")
                slider("Bounce", value: $settings.motionTuning.growBounce, in: 0...0.7, step: 0.01, format: "%.2f")
                slider("Spring", value: $settings.motionTuning.growSpring, in: 0.1...1.5, step: 0.01, format: "%.2f s")
            } header: {
                Text("Blocks opening")
            } footer: {
                Text("Overlap: how far into the next block's stretch a block is still opening. The curve (a cubic Bézier, as in CSS) is how a "
                     + "block opens over its stretch; its width follows it as a spring of that bounce and duration.")
                    .foregroundStyle(.secondary)
            }
            Section {
                slider("Room", value: $settings.motionTuning.finishRoom, in: 0...0.3, step: 0.005, format: "%.3f")
                slider("Bounce", value: $settings.motionTuning.finishBounce, in: 0...0.8, step: 0.01, format: "%.2f")
                slider("Spring", value: $settings.motionTuning.finishSpring, in: 0.1...1.2, step: 0.01, format: "%.2f s")
                slider("Creep", value: $settings.motionTuning.finishCreep, in: 0...1, step: 0.01, format: "%.2f")
                slider("Creep time", value: $settings.motionTuning.finishCreepTime, in: 1...40, step: 0.5, format: "%.1f s")
            } header: {
                Text("Finish")
            } footer: {
                Text("While the blocks open, the chart keeps this share of its width empty at its right and creeps into it, up to Creep of it, ever slower (Creep time); once the reading is over it springs into the rest, so the end is felt.")
                    .foregroundStyle(.secondary)
            }
            Section("Glide to new figures") {
                slider("Bounce", value: $settings.motionTuning.glideBounce, in: 0...0.7, step: 0.01, format: "%.2f")
                slider("Duration", value: $settings.motionTuning.glideDuration, in: 0.1...1.5, step: 0.01, format: "%.2f s")
            }
            Section("Refresh and freeing") {
                slider("Closing", value: $settings.motionTuning.closing, in: 0.05...1.5, step: 0.01, format: "%.2f s")
                slider("Closing stagger", value: $settings.motionTuning.closeStagger, in: 0...0.2, step: 0.005, format: "%.3f s")
                slider("Amber draining", value: $settings.motionTuning.draining, in: 0.05...2, step: 0.01, format: "%.2f s")
            }
            Section {
                slider("Pretend reading", value: $replaySeconds, in: 0.5...12, step: 0.5, format: "%.1f s")
                HStack {
                    Button("Replay") { NotificationCenter.default.post(name: ChartMotion.replay, object: replaySeconds) }
                        .keyboardShortcut("r", modifiers: [.command])
                    Spacer()
                    Button("Copy JSON") { copyJSON() }
                    Button("Reset", role: .destructive) { settings.motionTuning = MotionTuning() }
                        .disabled(settings.motionTuning == MotionTuning())
                }
            } header: {
                Text("Try it")
            } footer: {
                Text("Replay (⌘R) closes the charts on screen and opens them again over a pretend reading of that length. "
                     + "Changes apply at once and are kept until reset.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 400, minHeight: 560)
    }

    private func slider(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double, format: String) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range, step: step)
                Text(String(format: format, value.wrappedValue)).monospacedDigit().frame(width: 58, alignment: .trailing)
            }
        }
    }

    private func copyJSON() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(settings.motionTuning), let text = String(data: data, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
#endif
