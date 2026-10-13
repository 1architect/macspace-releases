// Development builds only (`MACSPACE_DEV`, set by Scripts/Assemble.sh for a -dev build): a release has no design tools.
#if MACSPACE_DEV
import AppKit
import SwiftUI

/// Temporary: the Widget Type window (Design menu, ⌥⌘T). The tiles' typeface, weights and sizes, and their charts' layout, number of
/// blocks, gap and concentric corners (the page's layout too), applied as they change (`TileType`). Copy JSON hands the settled values over.
public struct WidgetTypeView: View {
    @ObservedObject private var settings = DesignSettings.shared

    public static let windowID = "widgetType"

    public init() {}

    private static let families = NSFontManager.shared.availableFontFamilies.sorted()

    public var body: some View {
        Form {
            Section("Typeface") {
                Picker("Family", selection: $settings.tileType.family) {
                    Text("System (SF Pro)").tag(String?.none)
                    Divider()
                    ForEach(Self.families, id: \.self) { family in
                        Text(family).font(.custom(family, size: 13)).tag(Optional(family))
                    }
                }
                Picker("Title weight", selection: $settings.tileType.titleWeight) {
                    ForEach(TypeWeight.allCases) { Text($0.title).tag($0) }
                }
                Picker("Status weight", selection: $settings.tileType.statusWeight) {
                    ForEach(TypeWeight.allCases) { Text($0.title).tag($0) }
                }
                slider("Optical size", value: $settings.tileType.opticalSize, in: 6...32, step: 1)
                    .disabled(settings.tileType.family != nil)
            }
            Section("Title sizes") {
                slider("Small tile", value: $settings.tileType.smallSize, in: 9...32, step: 0.5)
                slider("Small tile, tall", value: $settings.tileType.mediumSize, in: 9...32, step: 0.5)
                slider("Large tile", value: $settings.tileType.largeSize, in: 9...40, step: 0.5)
                slider("Large tile, tall", value: $settings.tileType.largeTallSize, in: 9...40, step: 0.5)
            }
            Section("Other text") {
                slider("Status line", value: $settings.tileType.statusScale, in: 0.5...1.3, step: 0.05, format: "×%.2f")
                slider("Small text", value: $settings.tileType.smallTextSize, in: 8...16, step: 0.5)
            }
            Section("Charts") {
                Picker("Tile layout", selection: $settings.tileType.tileChartStyle) {
                    ForEach(ChartStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Page layout", selection: $settings.tileType.pageChartStyle) {
                    ForEach(ChartStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Stepper(value: $settings.tileType.tileBlocks, in: 0...10) {
                    LabeledContent("Blocks on a tile", value: settings.tileType.tileBlocks == 0 ? "All" : "\(settings.tileType.tileBlocks)")
                }
                slider("Gap on a tile", value: $settings.tileType.tileGap, in: 1...10, step: 0.5)
                Toggle("Concentric outer corners", isOn: $settings.tileType.concentricCorners)
            }
            Section {
                HStack {
                    Button("Copy JSON") { copyJSON() }
                    Spacer()
                    Button("Reset", role: .destructive) { settings.tileType = TileType() }
                        .disabled(settings.tileType == TileType())
                }
            } footer: {
                Text("Changes apply to the dashboard at once and are kept until reset.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 380, minHeight: 520)
    }

    private func slider(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double,
                        format: String = "%.1f pt") -> some View {
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
        guard let data = try? encoder.encode(settings.tileType), let text = String(data: data, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
#endif
