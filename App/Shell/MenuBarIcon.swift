import AppKit

/// The menu bar icon: the nine circles of the app's design (Circles.svg), drawn as a template image so it takes the
/// menu bar's color. While something is being cleaned the circles breathe one after another, a wave running through them, as a
/// tile's chart does while it loads (`LoadingWave`); `StatusItemController` plays it, and when the cleanup ends the icon rests full.
enum MenuBarIcon {
    static let frameRate: Double = 30

    // MARK: Drawing

    /// The circles in the order they leave and come back: a snake through the rows.
    static let order = [0, 1, 2, 5, 4, 3, 6, 7, 8]

    /// How much of circle `rank` (its place in `order`) shows at `date` while the icon breathes: the small-indicator loading wave
    /// (`LoadingWave.opacity`), the same pace and the same spread over the nine circles. nil: at rest, every circle full.
    static func visibility(rank: Int, at date: Date?) -> Double {
        guard let date else { return 1 }
        return LoadingWave.opacity(date, index: rank, count: order.count, loading: true, reduceMotion: false)
    }

    /// The design's circles in its 1024 × 1024 canvas (Circles.svg): three columns and rows, the ones in the bottom row the lowest;
    /// the bottom middle one is a little larger than the rest.
    static let columns: [CGFloat] = [208.4, 512.0, 815.6]
    static let rows: [CGFloat] = [218.9, 512.8, 803.5]
    static let radius: CGFloat = 115.0
    static let largeRadius: CGFloat = 120.0
    static let largeIndex = 7
    static let pointSize = NSSize(width: 18, height: 18)

    static func image(at date: Date?) -> NSImage {
        let image = NSImage(size: pointSize, flipped: true) { bounds in
            let content = CGRect(x: columns[0] - radius, y: rows[0] - radius, width: columns[2] - columns[0] + 2 * radius,
                                 height: rows[2] + largeRadius - rows[0] + radius)
            let scale = min(bounds.width, bounds.height) * 0.9 / max(content.width, content.height)
            let origin = CGPoint(x: (bounds.width - content.width * scale) / 2, y: (bounds.height - content.height * scale) / 2)
            for row in 0..<3 {
                for column in 0..<3 {
                    let index = row * 3 + column
                    let shown = visibility(rank: order.firstIndex(of: index) ?? index, at: date)
                    // A circle shrinks a little toward its middle as it dims, as a loading dot does (`LoadingDots`).
                    let size = (index == largeIndex ? largeRadius : radius) * scale * (0.75 + 0.25 * shown)
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
