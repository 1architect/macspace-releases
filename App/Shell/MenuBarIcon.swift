import AppKit
import SwiftUI

/// The menu bar icon: the nine rounded squares of the app's design (Interiors3.svg), drawn as a template image so it takes the
/// menu bar's color. While something is being cleaned the squares leave one after another, shrinking as they fade, and come back
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

    /// The squares in the order they leave and come back: a snake through the rows.
    static let order = [0, 1, 2, 5, 4, 3, 6, 7, 8]

    /// How much of square `rank` (its place in `order`) shows at `phase`: they fade out one after another in the first part of the
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

    /// The design's squares in its 1024 × 1024 canvas (Interiors3.svg): three columns and rows of 231.4 × 230 with corners of 11.5.
    static let columns: [CGFloat] = [92.7, 396.3, 699.9]
    static let rows: [CGFloat] = [104.7, 397.0, 689.3]
    static let squareSize = CGSize(width: 231.4, height: 230.0)
    static let cornerRadius: CGFloat = 11.5
    static let pointSize = NSSize(width: 18, height: 18)

    static func image(phase: Double) -> NSImage {
        let image = NSImage(size: pointSize, flipped: true) { bounds in
            let content = CGRect(x: columns[0], y: rows[0], width: columns[2] + squareSize.width - columns[0],
                                 height: rows[2] + squareSize.height - rows[0])
            let scale = min(bounds.width, bounds.height) * 0.9 / max(content.width, content.height)
            let origin = CGPoint(x: (bounds.width - content.width * scale) / 2, y: (bounds.height - content.height * scale) / 2)
            NSColor.black.setFill()
            for row in 0..<3 {
                for column in 0..<3 {
                    let index = row * 3 + column
                    let shown = visibility(rank: order.firstIndex(of: index) ?? index, phase: phase)
                    guard shown > 0.01 else { continue }
                    // A square shrinks toward its middle as it fades.
                    let size = CGSize(width: squareSize.width * scale * (0.55 + 0.45 * shown), height: squareSize.height * scale * (0.55 + 0.45 * shown))
                    let middle = CGPoint(x: origin.x + (columns[column] - content.minX + squareSize.width / 2) * scale,
                                         y: origin.y + (rows[row] - content.minY + squareSize.height / 2) * scale)
                    let rect = CGRect(x: middle.x - size.width / 2, y: middle.y - size.height / 2, width: size.width, height: size.height)
                    let radius = cornerRadius * scale * (0.55 + 0.45 * shown)
                    NSColor.black.withAlphaComponent(shown).setFill()
                    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
                }
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
