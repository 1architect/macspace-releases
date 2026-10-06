import AppKit
import MacSpaceSdk
import SwiftUI

/// Temporary: the Shader Studio window. Pick a part of the app (here, or with "Pick in window" by clicking it in the window) and set
/// its colors and its shading: one main color per tile color, from which the ground, the steps and the text are worked out; the
/// action color, from which its light and deep forms are; and a shading (flat, lit, glow, orb, aurora, with blur, grain and motion)
/// per part. Changes apply live and are kept per palette; Copy JSON hands the settled values over.
public struct ColorLabView: View {
    @ObservedObject private var settings = DesignSettings.shared

    public static let windowID = "colorLab"

    public init() {}

    private var target: FillTarget { settings.studioTarget }

    public var body: some View {
        Form {
            Section {
                Picker("Palette", selection: $settings.scheme) {
                    ForEach(PaletteScheme.allCases) { Text($0.title).tag($0) }
                }
                Toggle(isOn: $settings.studioPicking) {
                    Label("Pick in window", systemImage: "scope")
                }
                Picker("Editing", selection: $settings.studioTarget) {
                    ForEach(FillTarget.all) { Text($0.title + (changed($0) ? " •" : "")).tag($0) }
                }
                HStack {
                    Button("Copy JSON") { copyJSON() }
                    Button("Reset this palette", role: .destructive) { settings.lab = LabOverrides() }.disabled(settings.lab.isEmpty)
                    Spacer()
                    Toggle("Liquid Glass tiles", isOn: $settings.glass).toggleStyle(.checkbox)
                }
            } footer: {
                Text(settings.studioPicking ? "Click a tile, the main button or the window's background to edit it."
                                            : "Changes apply to the open window at once and are kept per palette.")
                    .foregroundStyle(.secondary)
            }

            Section("Preview") { StudioPreview(target: target) }

            colorSection

            switch target {
            case .tiles, .tile:
                ShadingSection(title: "Ground shading", target: target)
                ShadingSection(title: "Chart elements shading", target: .chartElements)
            default:
                ShadingSection(title: "Shading", target: target)
            }

            Section {
                DisclosureGroup("Gradient fill") {
                    Toggle("Custom fill", isOn: Binding(
                        get: { settings.lab.fills[target.key] != nil },
                        set: { on in settings.lab.fills[target.key] = on ? FillSpec() : nil }))
                    if settings.lab.fills[target.key] != nil {
                        FillEditor(fill: Binding(get: { settings.lab.fills[target.key] ?? FillSpec() },
                                                 set: { settings.lab.fills[target.key] = $0 }),
                                   element: elementColor(target))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, minHeight: 640)
        .environment(\.design, settings.design)
        .onDisappear { settings.studioPicking = false }
    }

    @ViewBuilder
    private var colorSection: some View {
        switch target {
        case .tiles:
            Section("Main colors") {
                ForEach(TileTint.allCases, id: \.self) { MainColorRow(tint: $0) }
            }
        case let .tile(tint):
            Section("Main color") { MainColorRow(tint: tint) }
        case .chartElements:
            Section("Colors") {
                Text("Chart elements take the steps of their tile's main color; pick a tile to change them.").foregroundStyle(.secondary)
            }
        case .mainButton:
            Section("Action color") {
                let design = settings.design
                HStack {
                    colorPicker("Action", .action, original: settings.scheme.action.fill)
                    Spacer()
                    Swatches(colors: [design.actionLight, design.actionDeep])
                }
                Text("Its light form (hover, progress) and deep form (its text) follow it.").foregroundStyle(.secondary)
            }
        case .window:
            Section("Text") {
                colorPicker("Ink (page and tile text)", .ink, original: settings.scheme.isLight ? Color(hex: 0x1C1C1E) : .white)
            }
        }
    }

    private func changed(_ target: FillTarget) -> Bool {
        let lab = settings.lab
        if lab.fills[target.key] != nil || lab.shadings[target.key] != nil { return true }
        if case let .tile(tint) = target { return lab.mains[tint.rawValue] != nil }
        if case .tiles = target { return !lab.mains.isEmpty }
        return false
    }

    /// The color an element's fill starts from: what "element color" stops take in the preview.
    private func elementColor(_ target: FillTarget) -> Color {
        let design = settings.design
        switch target {
        case .window: return design.systemWindowColor
        case .tiles: return design.palette(.violet).base
        case let .tile(tint): return design.palette(tint).base
        case .chartElements: return design.palette(.violet).step(4)
        case .mainButton: return design.action
        }
    }

    private func colorPicker(_ title: String, _ role: ColorRole, original: Color) -> some View {
        HStack {
            Text(title)
            if settings.lab.colors[role.key] != nil {
                Button("Reset") { settings.lab.colors[role.key] = nil }.buttonStyle(.borderless)
            }
            ColorPicker("", selection: Binding(get: { settings.lab.colors[role.key]?.color ?? original },
                                               set: { settings.lab.colors[role.key] = LabColor($0) }),
                        supportsOpacity: false)
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

/// A tile color's main color, and the palette worked out from it: ground, the six steps, text.
private struct MainColorRow: View {
    let tint: TileTint
    @ObservedObject private var settings = DesignSettings.shared

    var body: some View {
        let palette = settings.design.palette(tint)
        HStack {
            Text(tint.rawValue.capitalized + (settings.lab.mains[tint.rawValue] == nil ? "" : " •")).frame(width: 74, alignment: .leading)
            ColorPicker("", selection: Binding(get: { settings.lab.mains[tint.rawValue]?.color ?? palette.step(3) },
                                               set: { settings.lab.mains[tint.rawValue] = LabColor($0) }),
                        supportsOpacity: false)
                .labelsHidden()
            Spacer()
            Swatches(colors: [palette.base] + palette.steps + [palette.text])
            Button("Reset") { settings.lab.mains[tint.rawValue] = nil }
                .buttonStyle(.borderless)
                .disabled(settings.lab.mains[tint.rawValue] == nil)
        }
    }
}

private struct Swatches: View {
    let colors: [Color]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(colors.indices, id: \.self) { index in
                RoundedRectangle(cornerRadius: 3).fill(colors[index]).frame(width: 16, height: 20)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 5).strokeBorder(.primary.opacity(0.15)))
    }
}

/// What the part being edited looks like: a tile with marks and a caption, the main button, or a piece of window.
private struct StudioPreview: View {
    let target: FillTarget
    @ObservedObject private var settings = DesignSettings.shared

    var body: some View {
        let design = settings.design
        switch target {
        case .tiles, .tile, .chartElements:
            let tints: [TileTint] = { if case let .tile(tint) = target { return [tint] } else { return TileTint.allCases } }()
            HStack(spacing: 8) {
                ForEach(tints, id: \.self) { tint in tile(tint, design: design, large: tints.count == 1) }
            }
        case .mainButton:
            let shape = RoundedRectangle(cornerRadius: 15.5, style: .continuous)
            Text("Free 2.3 GB")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(design.actionDeep)
                .padding(.horizontal, 15)
                .padding(.vertical, 7)
                .background { ShadedFill(shape: shape, color: design.action, accent: design.actionLight, fill: design.fill(.mainButton),
                                         shading: design.shading(.mainButton), light: design.isLight) }
                .frame(maxWidth: .infinity, minHeight: 80)
        case .window:
            ShadedFill(shape: RoundedRectangle(cornerRadius: 14, style: .continuous), color: design.systemWindowColor, accent: design.action,
                       fill: design.fill(.window), shading: design.shading(.window), light: design.backgroundIsLight)
                .frame(height: 120)
        }
    }

    private func tile(_ tint: TileTint, design: Design, large: Bool) -> some View {
        let palette = design.palette(tint)
        let shape = RoundedRectangle(cornerRadius: large ? 19 : 12, style: .continuous)
        return ShadedFill(shape: shape, color: palette.base, accent: palette.step(3), fill: design.fill(.tile(tint)),
                          shading: design.shading(.tile(tint)), light: design.isLight)
            .overlay(alignment: .topLeading) {
                HStack(spacing: large ? 6 : 3) {
                    ForEach([5, 3, 1], id: \.self) { step in
                        Surface(shape: RoundedRectangle(cornerRadius: large ? 5 : 3, style: .continuous), color: palette.step(step), glass: false)
                            .frame(width: large ? 46 : 14, height: large ? 46 : 14)
                    }
                }
                .padding(large ? 14 : 8)
            }
            .overlay(alignment: .bottomTrailing) {
                if large {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("system data").font(.system(size: 18, weight: .bold))
                        Text("2.3 GB can be freed").font(.system(size: 18, weight: .light))
                    }
                    .foregroundStyle(design.ink)
                    .padding(14)
                }
            }
            .frame(height: large ? 180 : 80)
    }
}

/// A part's shading: its style and the sliders the style uses. The part shows its default (tile grounds: lit) until it is changed.
private struct ShadingSection: View {
    let title: String
    let target: FillTarget
    @ObservedObject private var settings = DesignSettings.shared

    var body: some View {
        let custom = settings.lab.shadings[target.key] != nil
        let spec = Binding<ShadingSpec>(
            get: { settings.lab.shadings[target.key] ?? settings.design.shading(target) ?? ShadingSpec(style: .flat) },
            set: { settings.lab.shadings[target.key] = $0 })
        Section {
            Picker("Style", selection: Binding(get: { spec.wrappedValue.style }, set: { style in var s = spec.wrappedValue; s.adopt(style); spec.wrappedValue = s })) {
                ForEach(ShadingSpec.Style.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            let style = spec.wrappedValue.style
            if style != .flat {
                slider("Brightness", spec.brightness, 0...1)
                if style != .lit { slider("Blur", spec.blur, 0...1) }
                slider("Size", spec.size, 0.1...2)
                if style != .aurora {
                    slider("Position x", spec.x, -0.2...1.2)
                    slider("Position y", spec.y, -0.2...1.2)
                }
                if style != .lit { slider("Animation", spec.speed, 0...1) }
                HStack {
                    Toggle("Own light color", isOn: Binding(get: { spec.wrappedValue.color != nil },
                                                            set: { spec.wrappedValue.color = $0 ? LabColor(red: 1, green: 1, blue: 1) : nil }))
                    Spacer()
                    if let color = spec.wrappedValue.color {
                        ColorPicker("", selection: Binding(get: { color.color }, set: { spec.wrappedValue.color = LabColor($0) }), supportsOpacity: false)
                            .labelsHidden()
                    }
                }
            }
            DisclosureGroup("Inner shadow and light" + (spec.wrappedValue.innerShadow > 0 || spec.wrappedValue.innerLight > 0 ? " •" : "")) {
                slider("Shadow", spec.innerShadow, 0...1)
                slider("Shadow size", spec.innerShadowRadius, 1...40, format: "%.0f pt")
                slider("Shadow offset", spec.innerShadowY, -20...20, format: "%.0f pt")
                slider("Light", spec.innerLight, 0...1)
                slider("Light size", spec.innerLightRadius, 1...40, format: "%.0f pt")
            }
            DisclosureGroup("Outer shadow" + (spec.wrappedValue.outerShadow > 0 ? " •" : "")) {
                slider("Shadow", spec.outerShadow, 0...1)
                slider("Size", spec.outerShadowRadius, 0...40, format: "%.0f pt")
                slider("Offset", spec.outerShadowY, -20...30, format: "%.0f pt")
            }
            DisclosureGroup("Noise" + (spec.wrappedValue.noise > 0 ? " •" : "")) {
                slider("Amount", spec.noise, 0...1)
                slider("Grain size", spec.noiseSize, 0.25...4, format: "%.2f pt")
                slider("Animation", spec.noiseSpeed, 0...1)
                Toggle("Color grain", isOn: spec.noiseColor)
                Picker("Blend", selection: spec.noiseBlend) {
                    ForEach(ShadingSpec.NoiseBlend.allCases) { Text($0.title).tag($0) }
                }
            }
        } header: {
            HStack {
                Text(title + (custom ? " •" : ""))
                Spacer()
                if custom { Button("Reset") { settings.lab.shadings[target.key] = nil }.buttonStyle(.borderless) }
            }
        }
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, format: String = "%.2f") -> some View {
        HStack {
            Text(title).frame(width: 100, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: format, value.wrappedValue)).monospacedDigit().frame(width: 52, alignment: .trailing)
        }
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
