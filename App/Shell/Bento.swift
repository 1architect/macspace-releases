import CoreGraphics

/// Packs tiles into a grid: each tile takes a number of columns and of rows, goes into the first place with room for it (row by row,
/// left to right), and a tile one row high with empty cells after it stretches over them, so the grid stays a clean rectangle.
enum Bento {
    struct Placement: Equatable {
        var row: Int
        var column: Int
        /// Columns taken.
        var span: Int
        /// Rows taken.
        var height = 1
    }

    struct Size: Equatable {
        var width: Int
        var height: Int
    }

    /// Three columns once tiles can be at least ~190 points wide, else two.
    static func columns(for width: CGFloat) -> Int {
        width >= 3 * 190 + 2 * Theme.spacing ? 3 : 2
    }

    /// One placement per span, in the same order; every tile one row high.
    static func pack(spans: [Int], columns: Int) -> [Placement] {
        pack(sizes: spans.map { Size(width: $0, height: 1) }, columns: columns)
    }

    /// One placement per size, in the same order.
    static func pack(sizes: [Size], columns: Int) -> [Placement] {
        var grid: [[Int?]] = []
        var placements: [Placement] = []
        func isFree(_ row: Int, _ column: Int) -> Bool { row >= grid.count || grid[row][column] == nil }
        for size in sizes {
            let width = min(max(size.width, 1), columns), height = max(size.height, 1)
            var row = 0
            var column: Int?
            while column == nil {
                column = (0...(columns - width)).first { start in
                    (row..<row + height).allSatisfy { r in (start..<start + width).allSatisfy { isFree(r, $0) } }
                }
                if column == nil { row += 1 }
            }
            let placement = Placement(row: row, column: column!, span: width, height: height)
            while grid.count < row + height { grid.append(Array(repeating: nil, count: columns)) }
            for r in row..<row + height { for c in placement.column..<placement.column + width { grid[r][c] = placements.count } }
            placements.append(placement)
        }
        // Empty cells: the one-row tile on their left takes them.
        for r in grid.indices {
            for c in 1..<max(columns, 1) where grid[r][c] == nil {
                if let left = grid[r][c - 1], placements[left].height == 1 {
                    placements[left].span += 1
                    grid[r][c] = left
                }
            }
        }
        return placements
    }

    static func rows(_ placements: [Placement]) -> Int { placements.map { $0.row + $0.height }.max() ?? 0 }

    /// The tile's rectangle in a grid of `size`, rows sharing the height equally.
    static func frame(_ placement: Placement, columns: Int, rows: Int, in size: CGSize, spacing: CGFloat = Theme.spacing) -> CGRect {
        let columnWidth = (size.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        let rowHeight = (size.height - spacing * CGFloat(max(rows - 1, 0))) / CGFloat(max(rows, 1))
        return CGRect(x: CGFloat(placement.column) * (columnWidth + spacing), y: CGFloat(placement.row) * (rowHeight + spacing),
                      width: columnWidth * CGFloat(placement.span) + spacing * CGFloat(placement.span - 1),
                      height: rowHeight * CGFloat(placement.height) + spacing * CGFloat(placement.height - 1))
    }
}
