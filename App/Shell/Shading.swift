import AppKit
import SwiftUI

// Temporary, with the Color Lab: the Shader Studio's shading of the window, the tile grounds, the chart elements and the main button
// (light, glow, a sphere, moving color, blur and grain), and the palette worked out from one main color per tile color.

/// How a surface is lit over its color.
struct ShadingSpec: Codable, Equatable, Sendable {
    enum Style: String, Codable, CaseIterable, Identifiable, Sendable {
        /// The color alone.
        case flat
        /// A faint light from the top left: the tiles' look until now.
        case lit
        /// A soft blurred light rising from an edge.
        case glow
        /// A lit sphere of the light color in the color, with a highlight.
        case orb
        /// Blobs of the palette's colors drifting through each other.
        case aurora

        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    var style: Style = .lit
    /// How strong the light is, 0...1.
    var brightness: Double = 0.07
    /// How soft the light's edge is, 0...1.
    var blur: Double = 0.5
    /// Film grain over the surface, 0...1.
    var noise: Double = 0
    /// How fast the light moves, 0 still ... 1.
    var speed: Double = 0
    /// The light's size, as a fraction of the surface.
    var size: Double = 0.8
    /// Where the light sits, as a fraction of the surface.
    var x: Double = 0.5
    var y: Double = 1
    /// The light's color; nil takes the surface's own accent (a tile's main color).
    var color: LabColor?

    /// A shadow inside the edge, as if the surface were pressed in: how dark, how far it reaches (points), and how far down it falls.
    var innerShadow: Double = 0
    var innerShadowRadius: Double = 8
    var innerShadowY: Double = 2
    /// A light inside the edge, as if lit from within: how bright and how far it reaches (points).
    var innerLight: Double = 0
    var innerLightRadius: Double = 10
    /// A shadow outside the surface: how dark, how far it spreads (points), and how far down it falls.
    var outerShadow: Double = 0
    var outerShadowRadius: Double = 12
    var outerShadowY: Double = 4

    /// How the grain is laid over the color.
    enum NoiseBlend: String, Codable, CaseIterable, Identifiable, Sendable {
        case overlay, softLight, screen, multiply
        var id: String { rawValue }
        var title: String {
            switch self {
            case .overlay: return "Overlay"
            case .softLight: return "Soft light"
            case .screen: return "Screen"
            case .multiply: return "Multiply"
            }
        }
        var mode: BlendMode {
            switch self {
            case .overlay: return .overlay
            case .softLight: return .softLight
            case .screen: return .screen
            case .multiply: return .multiply
            }
        }
    }

    /// One grain's size, in points.
    var noiseSize: Double = 0.5
    /// How often the grain changes, 0 still ... 1 (24 times a second).
    var noiseSpeed: Double = 0
    /// Grain in color rather than grey.
    var noiseColor = false
    var noiseBlend = NoiseBlend.overlay

    init(style: Style = .lit, brightness: Double = 0.07) {
        self.style = style
        self.brightness = brightness
    }

    /// The tiles' look until now: lit from the top left, stronger on light palettes.
    static func classic(light: Bool) -> ShadingSpec { ShadingSpec(style: .lit, brightness: light ? 0.5 : 0.07) }

    /// Where a style puts its light by default, and how strong it is.
    mutating func adopt(_ style: Style) {
        self.style = style
        switch style {
        case .flat: break
        case .lit: brightness = 0.1; x = 0; y = 0; size = 1
        case .glow: brightness = 0.85; x = 0.5; y = 1.05; size = 0.9; blur = 0.55
        case .orb: brightness = 0.9; x = 0.62; y = 0.58; size = 0.95; blur = 0.6
        case .aurora: brightness = 0.6; size = 0.8; blur = 0.7; if speed == 0 { speed = 0.3 }
        }
    }

    /// Whether its light moves.
    var moves: Bool { speed > 0 && (style == .glow || style == .orb || style == .aurora) }
    /// Whether its grain changes.
    var grainMoves: Bool { noise > 0 && noiseSpeed > 0 }

    private enum CodingKeys: String, CodingKey {
        case style, brightness, blur, noise, speed, size, x, y, color
        case innerShadow, innerShadowRadius, innerShadowY, innerLight, innerLightRadius, outerShadow, outerShadowRadius, outerShadowY
        case noiseSize, noiseSpeed, noiseColor, noiseBlend
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        style = try c.decodeIfPresent(Style.self, forKey: .style) ?? .lit
        brightness = try c.decodeIfPresent(Double.self, forKey: .brightness) ?? 0.07
        blur = try c.decodeIfPresent(Double.self, forKey: .blur) ?? 0.5
        noise = try c.decodeIfPresent(Double.self, forKey: .noise) ?? 0
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 0
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? 0.8
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0.5
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 1
        color = try c.decodeIfPresent(LabColor.self, forKey: .color)
        innerShadow = try c.decodeIfPresent(Double.self, forKey: .innerShadow) ?? 0
        innerShadowRadius = try c.decodeIfPresent(Double.self, forKey: .innerShadowRadius) ?? 8
        innerShadowY = try c.decodeIfPresent(Double.self, forKey: .innerShadowY) ?? 2
        innerLight = try c.decodeIfPresent(Double.self, forKey: .innerLight) ?? 0
        innerLightRadius = try c.decodeIfPresent(Double.self, forKey: .innerLightRadius) ?? 10
        outerShadow = try c.decodeIfPresent(Double.self, forKey: .outerShadow) ?? 0
        outerShadowRadius = try c.decodeIfPresent(Double.self, forKey: .outerShadowRadius) ?? 12
        outerShadowY = try c.decodeIfPresent(Double.self, forKey: .outerShadowY) ?? 4
        noiseSize = try c.decodeIfPresent(Double.self, forKey: .noiseSize) ?? 0.5
        noiseSpeed = try c.decodeIfPresent(Double.self, forKey: .noiseSpeed) ?? 0
        noiseColor = try c.decodeIfPresent(Bool.self, forKey: .noiseColor) ?? false
        noiseBlend = try c.decodeIfPresent(NoiseBlend.self, forKey: .noiseBlend) ?? .overlay
    }
}

/// A shape in its color (or the Color Lab's fill), lit by a shading, with grain. Nothing in it takes the pointer.
struct ShadedFill<S: Shape>: View {
    let shape: S
    let color: Color
    /// The light's color when the shading names none: a tile's main color, a button's light color.
    var accent: Color = .white
    var fill: FillSpec?
    var shading: ShadingSpec?
    /// Lights add on dark grounds and blend normally on light ones.
    var light = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let shading, !reduceMotion, shading.moves || shading.grainMoves {
            // As often as the light or the grain needs: the grain alone changes 6 to 24 times a second.
            let interval = shading.moves ? 1.0 / 30 : 1 / (6 + 18 * shading.noiseSpeed)
            TimelineView(.animation(minimumInterval: interval)) { context in
                layers(shading, time: context.date.timeIntervalSinceReferenceDate)
            }
        } else {
            layers(shading, time: 0)
        }
    }

    private func layers(_ shading: ShadingSpec?, time: Double) -> some View {
        LabFill(shape: shape, color: color, fill: fill)
            .background {
                // Outside: drawn by a copy of the shape under it, so only the shadow shows.
                if let shading, shading.outerShadow > 0 {
                    shape.fill(color)
                        .shadow(color: .black.opacity(shading.outerShadow), radius: shading.outerShadowRadius, y: shading.outerShadowY)
                }
            }
            .overlay {
                if let shading, shading.style != .flat {
                    GeometryReader { proxy in
                        ShadingLight(shading: shading, size: proxy.size, accent: shading.color?.color ?? accent, ground: color,
                                     light: light, time: time * shading.speed * 1.6)
                    }
                    .clipShape(shape)
                }
            }
            .overlay {
                // Inside the edge: a thick blurred stroke of the shape, kept inside it.
                if let shading, shading.innerLight > 0 {
                    shape.stroke(Color.white, lineWidth: shading.innerLightRadius)
                        .blur(radius: shading.innerLightRadius / 2)
                        .opacity(shading.innerLight)
                        .blendMode(light ? .normal : .plusLighter)
                        .clipShape(shape)
                }
            }
            .overlay {
                if let shading, shading.innerShadow > 0 {
                    shape.stroke(Color.black, lineWidth: shading.innerShadowRadius * 2)
                        .blur(radius: shading.innerShadowRadius / 2)
                        .offset(y: shading.innerShadowY)
                        .opacity(shading.innerShadow)
                        .clipShape(shape)
                }
            }
            .overlay {
                if let shading, shading.noise > 0 {
                    NoiseTexture.view(size: shading.noiseSize, color: shading.noiseColor,
                                      frame: shading.grainMoves ? Int(time * (6 + 18 * shading.noiseSpeed)) : 0)
                        .blendMode(shading.noiseBlend.mode)
                        .opacity(shading.noise)
                        .clipShape(shape)
                }
            }
            .allowsHitTesting(false)
    }
}

/// The light of a shading over a surface of `size`; `time` already scaled by its speed.
private struct ShadingLight: View {
    let shading: ShadingSpec
    let size: CGSize
    let accent: Color
    let ground: Color
    let light: Bool
    let time: Double

    var body: some View {
        let w = size.width, h = size.height, short = max(min(w, h), 1), long = max(w, h)
        let blur = shading.blur * short * 0.35 + 1
        let blend: BlendMode = light ? .normal : .plusLighter
        switch shading.style {
        case .flat:
            EmptyView()
        case .lit:
            Rectangle().fill(RadialGradient(colors: [.white.opacity(shading.brightness), .clear],
                                            center: UnitPoint(x: shading.x, y: shading.y), startRadius: 0, endRadius: long * 1.6 * shading.size + 1))
        case .glow:
            // Breathes and sways a little when animated.
            let sway = sin(time) * 0.08
            let breath = 1 + sin(time * 0.7) * 0.08
            Ellipse()
                .fill(accent)
                .frame(width: w * shading.size * 1.4 * breath, height: h * shading.size * 0.75 * breath)
                .position(x: w * (shading.x + sway), y: h * shading.y)
                .blur(radius: blur)
                .opacity(shading.brightness)
                .blendMode(blend)
        case .orb:
            let d = long * shading.size
            let cx = w * (shading.x + sin(time) * 0.05), cy = h * (shading.y + cos(time * 0.8) * 0.05)
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [accent, accent.mix(with: ground, by: 0.5), ground.opacity(0)],
                                         center: .center, startRadius: 0, endRadius: d / 2))
                    .frame(width: d, height: d)
                    .position(x: cx, y: cy)
                    .blur(radius: blur * 0.6)
                    .opacity(shading.brightness)
                // The highlight, up and to the left on the sphere.
                Circle()
                    .fill(.white)
                    .frame(width: d * 0.32, height: d * 0.32)
                    .position(x: cx - d * 0.2, y: cy - d * 0.22)
                    .blur(radius: blur * 0.5 + d * 0.06)
                    .opacity(shading.brightness * (light ? 0.5 : 0.3))
                    .blendMode(blend)
            }
        case .aurora:
            // Three blobs: the light color, and the same hue turned either way, drifting on slow loops.
            let d = short * shading.size * 1.4
            let colors = [accent, accent.hueRotated(40), accent.hueRotated(-50)]
            ZStack {
                ForEach(0..<3, id: \.self) { index in
                    let phase = Double(index) * 2.1
                    Circle()
                        .fill(colors[index])
                        .frame(width: d, height: d)
                        .position(x: w * (0.5 + 0.38 * sin(time * (0.6 + 0.15 * Double(index)) + phase)),
                                  y: h * (0.5 + 0.34 * cos(time * (0.5 + 0.1 * Double(index)) + phase * 1.3)))
                        .blur(radius: blur + d * 0.15)
                        .opacity(shading.brightness)
                        .blendMode(blend)
                }
            }
        }
    }
}

/// Grain, drawn once per size and kind and tiled. Animated, the tiling shifts to another place each frame, which looks like new grain.
enum NoiseTexture {
    private static let side = 128
    @MainActor private static var cache: [String: NSImage] = [:]

    /// `size`: one grain, in points. `color`: grain in color rather than grey.
    @MainActor static func image(size: Double, color: Bool) -> NSImage {
        let grain = (max(size, 0.25) * 4).rounded() / 4
        let key = "\(grain)-\(color)"
        if let image = cache[key] { return image }
        let channels = color ? 3 : 1
        var pixels = [UInt8](repeating: 0, count: side * side * channels)
        var generator = SystemRandomNumberGenerator()
        for index in pixels.indices { pixels[index] = UInt8.random(in: 0...255, using: &generator) }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: channels,
                                   hasAlpha: false, isPlanar: false, colorSpaceName: color ? .deviceRGB : .deviceWhite,
                                   bytesPerRow: side * channels, bitsPerPixel: 8 * channels)!
        pixels.withUnsafeBufferPointer { buffer in rep.bitmapData!.update(from: buffer.baseAddress!, count: buffer.count) }
        rep.size = NSSize(width: Double(side) * grain, height: Double(side) * grain)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        cache[key] = image
        return image
    }

    @MainActor static func view(size: Double, color: Bool, frame: Int) -> some View {
        let image = image(size: size, color: color)
        let tile = image.size
        // A place in the tile picked from the frame number, the same for the same frame.
        var hash = UInt64(bitPattern: Int64(frame)) &* 0x9E3779B97F4A7C15
        hash ^= hash >> 29
        let dx = Double(hash % 1000) / 1000 * tile.width, dy = Double((hash / 1000) % 1000) / 1000 * tile.height
        return GeometryReader { proxy in
            Rectangle()
                .fill(ImagePaint(image: Image(nsImage: image).interpolation(.none)))
                .frame(width: proxy.size.width + tile.width, height: proxy.size.height + tile.height)
                .offset(x: -dx, y: -dy)
        }
    }
}

// MARK: The palette from one color

/// A color in OKLab, where equal steps of lightness look equal: the palette's steps are spaced in it.
struct OKLab {
    var l: Double
    var a: Double
    var b: Double

    var chroma: Double { (a * a + b * b).squareRoot() }
    var hue: Double { atan2(b, a) }

    init(l: Double, a: Double, b: Double) {
        self.l = l
        self.a = a
        self.b = b
    }

    init(l: Double, chroma: Double, hue: Double) {
        self.init(l: l, a: chroma * cos(hue), b: chroma * sin(hue))
    }

    init(_ color: LabColor) {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let r = linear(color.red), g = linear(color.green), b = linear(color.blue)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        self.init(l: 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                  a: 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                  b: 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    /// In sRGB, or nil when outside it.
    private var srgb: (Double, Double, Double)? {
        let l = pow(self.l + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(self.l - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(self.l - 0.0894841775 * a - 1.2914855480 * b, 3)
        let r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
        let g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
        let bl = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        let range = -0.0001...1.0001
        guard range.contains(r), range.contains(g), range.contains(bl) else { return nil }
        func gamma(_ c: Double) -> Double { let c = min(max(c, 0), 1); return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055 }
        return (gamma(r), gamma(g), gamma(bl))
    }

    /// The color in sRGB, its chroma lowered until it fits.
    var labColor: LabColor {
        var probe = self
        for _ in 0..<40 {
            if let (r, g, b) = probe.srgb { return LabColor(red: r, green: g, blue: b) }
            probe = OKLab(l: l, chroma: probe.chroma * 0.92, hue: hue)
        }
        let v = min(max(l, 0), 1)
        return LabColor(red: v, green: v, blue: v)
    }
}

enum PaletteRamp {
    /// A tile color's whole palette from its main color: the ground, six steps from just off the ground through the main color (the
    /// fourth step) to the strongest mark, and text that reads on all of them. Dark palettes run dark to light, light ones light to
    /// dark, as the hand-made ones do.
    static func palette(main: LabColor, light: Bool) -> TintPalette {
        let m = OKLab(main)
        let c = m.chroma, h = m.hue
        let lm = light ? min(max(m.l, 0.45), 0.72) : min(max(m.l, 0.5), 0.78)
        let ground = light ? 0.95 : 0.27
        let end = light ? 0.3 : 0.92
        func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
        let levels = [lerp(ground, lm, 0.12), lerp(ground, lm, 0.3), lerp(ground, lm, 0.62), lm, lerp(lm, end, 0.5), lerp(lm, end, 0.8)]
        // Chroma peaks at the main color and fades toward the ground and the far end.
        let chromas = [0.6, 0.72, 0.88, 1, 0.62, 0.38].map { $0 * c }
        func color(_ l: Double, _ chroma: Double) -> Color { OKLab(l: l, chroma: chroma, hue: h).labColor.color }
        return TintPalette(base: color(ground, c * (light ? 0.22 : 0.5)),
                           steps: zip(levels, chromas).map { color($0, $1) },
                           text: color(light ? 0.24 : 0.96, c * (light ? 0.5 : 0.1)))
    }

    /// The action color's lighter form (hover, progress) and its deep form (its text).
    static func action(_ fill: LabColor, light: Bool) -> (light: Color, deep: Color) {
        let m = OKLab(fill)
        let lighter = OKLab(l: light ? max(m.l - 0.08, 0) : min(m.l + 0.1, 0.95), chroma: m.chroma * 0.9, hue: m.hue)
        let deep = OKLab(l: 0.27, chroma: m.chroma * 0.45, hue: m.hue)
        return (lighter.labColor.color, deep.labColor.color)
    }
}

extension Color {
    /// The same color with its hue turned by `degrees`, in OKLab.
    func hueRotated(_ degrees: Double) -> Color {
        let lab = OKLab(LabColor(self))
        return OKLab(l: lab.l, chroma: lab.chroma, hue: lab.hue + degrees * .pi / 180).labColor.color
    }
}

// MARK: Picking in the window

/// While the studio picks (its "Pick in window" switch), a click on what this is applied to selects it in the studio instead of doing
/// what it does, and what is selected is outlined.
struct StudioPickable<S: InsettableShape>: ViewModifier {
    let target: FillTarget
    let shape: S
    @ObservedObject private var settings = DesignSettings.shared

    func body(content: Content) -> some View {
        content.overlay {
            if settings.studioPicking {
                let selected = settings.studioTarget == target
                shape.fill(Color.white.opacity(0.001))
                    .overlay { shape.strokeBorder(Color.accentColor, lineWidth: selected ? 2.5 : 0) }
                    .contentShape(shape)
                    .onTapGesture { settings.studioTarget = target }
                    // The studio is in front while picking: the click that brings the window forward picks too.
                    .allowsWindowActivationEvents(true)
                    .help("Edit in the Shader Studio")
            }
        }
    }
}

extension View {
    func studioPickable<S: InsettableShape>(_ target: FillTarget, in shape: S) -> some View { modifier(StudioPickable(target: target, shape: shape)) }
}
