import AppKit
import MacSpaceSdk
import SwiftUI

/// Temporary: the Color Lab window. Every color role of the current palette, and fills (flat or gradient, with every stop and the
/// gradient's geometry) for the window, the tile grounds, the chart elements and the main button. Changes apply live and are kept
/// per palette; Copy JSON hands the settled values over.
public struct ColorLabView: View {
    @ObservedObject private var settings = DesignSettings.shared
    @State private var target: FillTarget = .tiles
    @State private var tint: TileTint = .violet

    public static let windowID = "colorLab"

    public init() {}

    public var body: some View {
        Form {
            Section {
                Picker("Palette", selection: $settings.scheme) {
                    ForEach(PaletteScheme.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Liquid Glass tiles", isOn: $settings.glass)
                Toggle("Glass chart elements", isOn: $settings.glassElements)
                HStack {
                    Button("Copy JSON") { copyJSON() }
                    Button("Reset this palette", role: .destructive) { settings.lab = LabOverrides() }.disabled(settings.lab.isEmpty)
                    Spacer()
                    Text(settings.lab.isEmpty ? "No changes" : "\(settings.lab.colors.count) color(s), \(settings.lab.fills.count) fill(s) changed")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Changes apply to the open window at once and are kept per palette.").foregroundStyle(.secondary)
            }

            Section("Fill") {
                Picker("Element", selection: $target) {
                    ForEach(FillTarget.all) { Text($0.title + (settings.lab.fills[$0.key] == nil ? "" : " •")).tag($0) }
                }
                Toggle("Custom fill", isOn: Binding(
                    get: { settings.lab.fills[target.key] != nil },
                    set: { on in settings.lab.fills[target.key] = on ? FillSpec() : nil }))
                if settings.lab.fills[target.key] != nil {
                    FillEditor(fill: Binding(get: { settings.lab.fills[target.key] ?? FillSpec() },
                                             set: { settings.lab.fills[target.key] = $0 }),
                               element: elementColor(target))
                }
            }

            Section("Colors") {
                Picker("Tile color", selection: $tint) {
                    ForEach(TileTint.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                .pickerStyle(.segmented)
                let palette = settings.scheme.palette(tint)
                colorRow("Ground", .base(tint), original: palette.base)
                ForEach(palette.steps.indices, id: \.self) { index in
                    colorRow("Step \(index + 1)", .step(tint, index), original: palette.steps[index])
                }
                colorRow("Text", .text(tint), original: palette.text)
            }

            Section("Every tile color") {
                colorRow("Action", .action, original: settings.scheme.action.fill)
                colorRow("Action, light", .actionLight, original: settings.scheme.action.light)
                colorRow("Action, deep (its text)", .actionDeep, original: settings.scheme.action.deep)
                colorRow("Ink (page and tile text)", .ink, original: settings.scheme.isLight ? Color(hex: 0x1C1C1E) : .white)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, minHeight: 640)
    }

    /// The color an element's fill starts from: what "element color" stops take in the preview.
    private func elementColor(_ target: FillTarget) -> Color {
        let design = settings.design
        switch target {
        case .window: return Color(white: design.isLight ? 0.92 : 0.13)
        case .tiles: return design.palette(tint).base
        case let .tile(tint): return design.palette(tint).base
        case .chartElements: return design.palette(tint).step(4)
        case .mainButton: return design.action
        }
    }

    private func colorRow(_ title: String, _ role: ColorRole, original: Color) -> some View {
        HStack {
            Text(title + (settings.lab.colors[role.key] == nil ? "" : " •"))
            Spacer()
            if settings.lab.colors[role.key] != nil {
                Button("Reset") { settings.lab.colors[role.key] = nil }.buttonStyle(.borderless)
            }
            ColorPicker("", selection: Binding(get: { settings.lab.colors[role.key]?.color ?? original },
                                               set: { settings.lab.colors[role.key] = LabColor($0) }),
                        supportsOpacity: true)
                .labelsHidden()
        }
    }

    private func copyJSON() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode([settings.scheme.rawValue: settings.lab]) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(String(decoding: data, as: UTF8.self), forType: .string)
    }
}

/// A fill's type, its stops and its geometry, with a live preview.
private struct FillEditor: View {
    @Binding var fill: FillSpec
    let element: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(fill.style(element))
            .frame(height: 90)
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.15)))
        Picker("Type", selection: $fill.kind) {
            ForEach(FillSpec.Kind.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)

        switch fill.kind {
        case .solid:
            EmptyView()
        case .linear:
            slider("Angle", $fill.angle, 0...360, format: "%.0f°")
        case .radial:
            slider("Center x", $fill.centerX, 0...1)
            slider("Center y", $fill.centerY, 0...1)
            slider("Start radius", $fill.startRadius, 0...2)
            slider("End radius", $fill.endRadius, 0...2)
        case .angular:
            slider("Center x", $fill.centerX, 0...1)
            slider("Center y", $fill.centerY, 0...1)
            slider("Start angle", $fill.startAngle, 0...360, format: "%.0f°")
        }

        ForEach($fill.stops) { $stop in
            StopEditor(stop: $stop, element: element, showsLocation: fill.kind != .solid,
                       remove: fill.stops.count > 1 ? { fill.stops.removeAll { $0.id == stop.id } } : nil)
        }
        if fill.kind != .solid {
            Button("Add stop") {
                let last = fill.stops.map(\.location).max() ?? 0
                fill.stops.append(FillStop(location: min(1, last + 0.25)))
            }
        }
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, format: String = "%.2f") -> some View {
        HStack {
            Text(title).frame(width: 90, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: format, value.wrappedValue)).monospacedDigit().frame(width: 48, alignment: .trailing)
        }
    }
}

/// One stop: the element's own color or a color of its own, shade, opacity and position.
private struct StopEditor: View {
    @Binding var stop: FillStop
    let element: Color
    let showsLocation: Bool
    let remove: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle().fill(stop.resolved(element: element)).frame(width: 16, height: 16)
                    .overlay(Circle().strokeBorder(.primary.opacity(0.2)))
                Toggle("Element color", isOn: $stop.usesElementColor)
                if !stop.usesElementColor {
                    ColorPicker("", selection: Binding(get: { stop.color.color }, set: { stop.color = LabColor($0) }), supportsOpacity: false)
                        .labelsHidden()
                }
                Spacer()
                if let remove { Button("Remove", role: .destructive, action: remove).buttonStyle(.borderless) }
            }
            if showsLocation { row("Position", $stop.location, 0...1) }
            row("Shade", $stop.shade, -1...1)
            row("Opacity", $stop.opacity, 0...1)
        }
        .padding(.vertical, 4)
    }

    private func row(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title).frame(width: 90, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: "%.2f", value.wrappedValue)).monospacedDigit().frame(width: 48, alignment: .trailing)
        }
    }
}
