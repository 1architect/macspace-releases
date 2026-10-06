import AppKit
import MacSpaceSdk
import SwiftUI

// Temporary: the Color Lab, a tool for trying colors and fills on the live app. Overrides are kept per palette in UserDefaults
// ("design.colorLab"), applied on top of `PaletteScheme`, and copied out as JSON once a look is settled.

/// A color in sRGB, as the lab stores it.
struct LabColor: Codable, Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(_ color: Color) {
        let resolved = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(red: resolved.redComponent, green: resolved.greenComponent, blue: resolved.blueComponent, alpha: resolved.alphaComponent)
    }

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
}

/// One stop of a fill: the element's own color or a color of its own, shaded toward black or white, at a position.
struct FillStop: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    /// 0...1 along the gradient.
    var location: Double
    /// The element's color (each chart block its own, each tile its own); otherwise `color`.
    var usesElementColor = true
    var color = LabColor(red: 1, green: 1, blue: 1)
    /// -1 black ... 0 unchanged ... 1 white.
    var shade: Double = 0
    var opacity: Double = 1

    func resolved(element: Color) -> Color {
        let base = usesElementColor ? element : color.color
        let shaded = shade > 0 ? base.mix(with: .white, by: shade) : (shade < 0 ? base.mix(with: .black, by: -shade) : base)
        return shaded.opacity(opacity)
    }
}

/// How an element is filled: a flat color or a gradient, with full control of its stops and geometry.
struct FillSpec: Codable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        case solid, linear, radial, angular
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    var kind: Kind = .linear
    var stops: [FillStop] = [FillStop(location: 0, shade: 0.15), FillStop(location: 1, shade: -0.15)]
    /// Linear: the direction the gradient runs, in degrees (0 left to right, 90 top to bottom).
    var angle: Double = 90
    /// Radial and angular: the center, as a fraction of the shape.
    var centerX: Double = 0.5
    var centerY: Double = 0.5
    /// Radial: where the gradient starts and ends, as a fraction of the shape's size.
    var startRadius: Double = 0
    var endRadius: Double = 0.75
    /// Angular: where the sweep starts, in degrees.
    var startAngle: Double = 0

    private func gradient(_ element: Color) -> Gradient {
        let sorted = stops.sorted { $0.location < $1.location }
        guard !sorted.isEmpty else { return Gradient(colors: [element]) }
        return Gradient(stops: sorted.map { Gradient.Stop(color: $0.resolved(element: element), location: min(max($0.location, 0), 1)) })
    }

    /// The fill for an element whose own color is `element`.
    func style(_ element: Color) -> AnyShapeStyle {
        let center = UnitPoint(x: centerX, y: centerY)
        switch kind {
        case .solid:
            return AnyShapeStyle((stops.first ?? FillStop(location: 0)).resolved(element: element))
        case .linear:
            let radians = angle * .pi / 180
            let dx = cos(radians) / 2, dy = sin(radians) / 2
            return AnyShapeStyle(LinearGradient(gradient: gradient(element), startPoint: UnitPoint(x: 0.5 - dx, y: 0.5 - dy),
                                                endPoint: UnitPoint(x: 0.5 + dx, y: 0.5 + dy)))
        case .radial:
            return AnyShapeStyle(EllipticalGradient(gradient: gradient(element), center: center,
                                                    startRadiusFraction: startRadius, endRadiusFraction: endRadius))
        case .angular:
            return AnyShapeStyle(AngularGradient(gradient: gradient(element), center: center, angle: .degrees(startAngle)))
        }
    }

    /// One color for what can only take one (the tint inside AppKit's glass): the gradient's middle.
    func average(_ element: Color) -> Color {
        let colors = stops.map { LabColor($0.resolved(element: element)) }
        guard !colors.isEmpty else { return element }
        let n = Double(colors.count)
        return LabColor(red: colors.map(\.red).reduce(0, +) / n, green: colors.map(\.green).reduce(0, +) / n,
                        blue: colors.map(\.blue).reduce(0, +) / n, alpha: colors.map(\.alpha).reduce(0, +) / n).color
    }
}

/// The parts of the app the lab can fill.
enum FillTarget: Hashable, Identifiable, Sendable {
    case window
    case tiles
    case tile(TileTint)
    case chartElements
    case mainButton

    var id: String { key }

    var key: String {
        switch self {
        case .window: return "window"
        case .tiles: return "tiles"
        case let .tile(tint): return "tile.\(tint.rawValue)"
        case .chartElements: return "chartElements"
        case .mainButton: return "mainButton"
        }
    }

    var title: String {
        switch self {
        case .window: return "Window"
        case .tiles: return "Tile grounds (all)"
        case let .tile(tint): return "Tile ground: \(tint.rawValue.capitalized)"
        case .chartElements: return "Chart elements"
        case .mainButton: return "Main button"
        }
    }

    static var all: [FillTarget] { [.window, .tiles] + TileTint.allCases.map { .tile($0) } + [.chartElements, .mainButton] }
}

/// The color roles the lab can change, per palette.
enum ColorRole: Hashable, Sendable {
    case base(TileTint)
    case step(TileTint, Int)
    case text(TileTint)
    case action, actionLight, actionDeep, ink

    var key: String {
        switch self {
        case let .base(tint): return "\(tint.rawValue).base"
        case let .step(tint, index): return "\(tint.rawValue).step\(index + 1)"
        case let .text(tint): return "\(tint.rawValue).text"
        case .action: return "action"
        case .actionLight: return "actionLight"
        case .actionDeep: return "actionDeep"
        case .ink: return "ink"
        }
    }
}

/// One palette's overrides.
struct LabOverrides: Codable, Equatable, Sendable {
    var colors: [String: LabColor] = [:]
    var fills: [String: FillSpec] = [:]
    /// The Shader Studio's main color per tile color (`TileTint.rawValue`): the whole palette is worked out from it (`PaletteRamp`).
    var mains: [String: LabColor] = [:]
    /// The Shader Studio's shading per part of the app (`FillTarget.key`).
    var shadings: [String: ShadingSpec] = [:]

    init() {}

    var isEmpty: Bool { colors.isEmpty && fills.isEmpty && mains.isEmpty && shadings.isEmpty }

    func color(_ role: ColorRole) -> Color? { colors[role.key]?.color }

    /// A tile's ground: its own fill, else the one for every tile.
    func fill(_ target: FillTarget) -> FillSpec? {
        if case .tile = target { return fills[target.key] ?? fills[FillTarget.tiles.key] }
        return fills[target.key]
    }

    /// A tile's ground: its own shading, else the one for every tile.
    func shading(_ target: FillTarget) -> ShadingSpec? {
        if case .tile = target { return shadings[target.key] ?? shadings[FillTarget.tiles.key] }
        return shadings[target.key]
    }

    private enum CodingKeys: String, CodingKey { case colors, fills, mains, shadings }

    /// Overrides saved before the studio have no main colors or shadings.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        colors = try c.decodeIfPresent([String: LabColor].self, forKey: .colors) ?? [:]
        fills = try c.decodeIfPresent([String: FillSpec].self, forKey: .fills) ?? [:]
        mains = try c.decodeIfPresent([String: LabColor].self, forKey: .mains) ?? [:]
        shadings = try c.decodeIfPresent([String: ShadingSpec].self, forKey: .shadings) ?? [:]
    }
}

extension TintPalette {
    /// The palette with the lab's colors for `tint` laid over it: the one worked out from its main color, then any single color.
    func applying(_ lab: LabOverrides, tint: TileTint, light: Bool) -> TintPalette {
        var palette = self
        if let main = lab.mains[tint.rawValue] { palette = PaletteRamp.palette(main: main, light: light) }
        guard !lab.colors.isEmpty else { return palette }
        return TintPalette(base: lab.color(.base(tint)) ?? palette.base,
                           steps: palette.steps.indices.map { lab.color(.step(tint, $0)) ?? palette.steps[$0] },
                           text: lab.color(.text(tint)) ?? palette.text)
    }
}

/// Fills a shape with an element's color, or with the lab's fill for it when there is one.
struct LabFill<S: Shape>: View {
    let shape: S
    let color: Color
    let fill: FillSpec?

    var body: some View {
        if let fill { shape.fill(fill.style(color)) } else { shape.fill(color) }
    }
}
