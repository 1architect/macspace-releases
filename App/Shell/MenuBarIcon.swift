import AppKit
import SwiftUI

/// The menu bar icon: the nine circles of the app's design (Circles.svg), drawn as a template image so it takes the
/// menu bar's color. While something is being cleaned the circles leave one after another, shrinking as they fade, and come back
/// the same way, over and over; when the cleanup ends the current round finishes and the icon rests full.
public struct MenuBarIcon: View {
    @ObservedObject var host: ModuleHost
    /// Where the animation is in its round, 0...1; 0 (and 1) is the full grid.
    @State private var phase: Double = 0
    @State private var animation: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(host: ModuleHost) {
        self.host = host
    }

    public var body: some View {
        Image(nsImage: Self.image(phase: phase))
            .accessibilityLabel(host.isCleaning ? "MacSpace, cleaning" : "MacSpace")
            .onChange(of: host.isCleaning, initial: true) { _, cleaning in if cleaning { animate() } }
    }

    static let round: TimeInterval = 2.4
    static let frameRate: Double = 30

    private func animate() {
        guard animation == nil, !reduceMotion else { return }
        animation = Task { @MainActor in
            let start = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1 / Self.frameRate))
                let next = (Date().timeIntervalSince(start) / Self.round).truncatingRemainder(dividingBy: 1)
                // Once the cleanup is over, the round in progress plays to its end (the phase wraps), so the icon rests full.
                if !host.isCleaning, next < phase { break }
                phase = next
            }
            phase = 0
            animation = nil
        }
    }

    // MARK: Drawing

    /// The circles in the order they leave and come back: a snake through the rows.
    static let order = [0, 1, 2, 5, 4, 3, 6, 7, 8]

    /// How much of circle `rank` (its place in `order`) shows at `phase`: they fade out one after another in the first part of the
    /// round, stay out for a moment, and fade back in the same order.
    static func visibility(rank: Int, phase: Double) -> Double {
        let out = 0.38, gap = 0.12, step = out / 9
        func ramp(_ start: Double) -> Double { min(max((phase - start) / (step * 1.6), 0), 1) }
        let leaving = ramp(Double(rank) * step)
        let returning = ramp(out + gap + Double(rank) * step)
        let shown = 1 - leaving + returning
        let t = min(max(shown, 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// The design's circles in its 1024 × 1024 canvas (Circles.svg): three columns and rows, the ones in the bottom row the lowest;
    /// the bottom middle one is a little larger than the rest.
    static let columns: [CGFloat] = [208.4, 512.0, 815.6]
    static let rows: [CGFloat] = [218.9, 512.8, 803.5]
    static let radius: CGFloat = 115.0
    static let largeRadius: CGFloat = 120.0
    static let largeIndex = 7
    static let pointSize = NSSize(width: 18, height: 18)

    static func image(phase: Double) -> NSImage {
        let image = NSImage(size: pointSize, flipped: true) { bounds in
            let content = CGRect(x: columns[0] - radius, y: rows[0] - radius, width: columns[2] - columns[0] + 2 * radius,
                                 height: rows[2] + largeRadius - rows[0] + radius)
            let scale = min(bounds.width, bounds.height) * 0.9 / max(content.width, content.height)
            let origin = CGPoint(x: (bounds.width - content.width * scale) / 2, y: (bounds.height - content.height * scale) / 2)
            for row in 0..<3 {
                for column in 0..<3 {
                    let index = row * 3 + column
                    let shown = visibility(rank: order.firstIndex(of: index) ?? index, phase: phase)
                    guard shown > 0.01 else { continue }
                    // A circle shrinks toward its middle as it fades.
                    let size = (index == largeIndex ? largeRadius : radius) * scale * (0.55 + 0.45 * shown)
                    let middle = CGPoint(x: origin.x + (columns[column] - content.minX) * scale,
                                         y: origin.y + (rows[row] - content.minY) * scale)
                    NSColor.black.withAlphaComponent(shown).setFill()
                    NSBezierPath(ovalIn: CGRect(x: middle.x - size, y: middle.y - size, width: size * 2, height: size * 2)).fill()
                }
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
