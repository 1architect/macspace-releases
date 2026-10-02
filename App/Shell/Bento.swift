import CoreGraphics

/// Packs tiles into a grid: each tile takes one column or two, goes into the first row with room for it, and the last tile of a
/// row that is not full stretches to the edge, so the grid is always a clean rectangle.
enum Bento {
    struct Placement: Equatable {
        var row: Int
        var column: Int
        var span: Int
    }

    /// Three columns once tiles can be at least ~190 points wide, else two.
    static func columns(for width: CGFloat) -> Int {
        width >= 3 * 190 + 2 * Theme.spacing ? 3 : 2
    }

    /// One placement per span, in the same order.
    static func pack(spans: [Int], columns: Int) -> [Placement] {
        var used: [Int] = []
        var placements: [Placement] = []
        for span in spans {
            let span = min(max(span, 1), columns)
            let row = used.firstIndex { columns - $0 >= span } ?? { used.append(0); return used.count - 1 }()
            placements.append(Placement(row: row, column: used[row], span: span))
            used[row] += span
        }
        for row in used.indices where used[row] < columns {
            if let last = placements.indices.filter({ placements[$0].row == row }).max(by: { placements[$0].column < placements[$1].column }) {
                placements[last].span += columns - used[row]
            }
        }
        return placements
    }

    static func rows(_ placements: [Placement]) -> Int { (placements.map(\.row).max() ?? -1) + 1 }

    /// The tile's rectangle in a grid of `size`, rows sharing the height equally.
    static func frame(_ placement: Placement, columns: Int, rows: Int, in size: CGSize, spacing: CGFloat = Theme.spacing) -> CGRect {
        let columnWidth = (size.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        let rowHeight = (size.height - spacing * CGFloat(max(rows - 1, 0))) / CGFloat(max(rows, 1))
        return CGRect(x: CGFloat(placement.column) * (columnWidth + spacing), y: CGFloat(placement.row) * (rowHeight + spacing),
                      width: columnWidth * CGFloat(placement.span) + spacing * CGFloat(placement.span - 1), height: rowHeight)
    }
}
