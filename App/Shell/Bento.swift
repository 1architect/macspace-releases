import CoreGraphics
import MacSpaceSdk

/// Packs tiles into a grid and rearranges them when stretching in place would leave a gap.
enum Bento {
    struct Placement: Equatable {
        var row: Int
        var column: Int
        /// Columns taken.
        var span: Int
        /// Rows taken.
        var height = 1
    }

    typealias Size = Tile.GridSize

    /// Three columns once tiles can be at least ~190 points wide, else two.
    static func columns(for width: CGFloat) -> Int {
        width >= 3 * 190 + 2 * Theme.spacing ? 3 : 2
    }

    /// One placement per span, in the same order; every tile one row high.
    static func pack(spans: [Int], columns: Int) -> [Placement] {
        pack(sizes: spans.map { Size(width: $0, height: 1) }, columns: columns)
    }

    /// One placement per size, in the same order. The fallback tile may grow beyond its maximum when no layout fits every preference.
    static func pack(sizes: [Size], columns: Int, maximumSizes: [Size?]? = nil, fallbackTile: Int? = nil) -> [Placement] {
        precondition(columns > 0)
        precondition(maximumSizes == nil || maximumSizes?.count == sizes.count)
        let minimums = sizes.enumerated().map { index, size in
            let maximum = maximumSizes?[index]
            return Size(width: max(1, min(size.width, columns, maximum?.width ?? columns)),
                        height: max(1, min(size.height, maximum?.height ?? size.height)))
        }
        var grid: [[Int?]] = []
        var placements: [Placement] = []
        func isFree(_ row: Int, _ column: Int) -> Bool { row >= grid.count || grid[row][column] == nil }
        for size in minimums {
            let width = size.width, height = size.height
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
                if let left = grid[r][c - 1], placements[left].height == 1,
                   placements[left].span < (maximumSizes?[left]?.width ?? columns) {
                    placements[left].span += 1
                    grid[r][c] = left
                }
            }
        }
        if let maximumSizes {
            // A capped tile can leave space along the bottom edge. Give it to tiles above it
            // when the whole width can grow without moving another tile.
            for index in placements.indices.reversed() {
                let placement = placements[index]
                let columns = placement.column..<(placement.column + placement.span)
                let maximumHeight = maximumSizes[index]?.height ?? grid.count
                while placements[index].height < maximumHeight {
                    let nextRow = placement.row + placements[index].height
                    guard nextRow < grid.count, columns.allSatisfy({ grid[nextRow][$0] == nil }) else { break }
                    for column in columns { grid[nextRow][column] = index }
                    placements[index].height += 1
                }
            }
            if grid.contains(where: { $0.contains(nil) }),
               let reflowed = reflow(minimums: minimums, maximums: maximumSizes, columns: columns, rowLimit: grid.count,
                                     fallbackTile: fallbackTile) {
                return reflowed
            }
        }
        return placements
    }

    private static func reflow(minimums: [Size], maximums: [Size?], columns: Int, rowLimit: Int, fallbackTile: Int?) -> [Placement]? {
        let minimumArea = minimums.reduce(0) { $0 + $1.width * $1.height }
        let minimumRows = max(minimums.map(\.height).max() ?? 0, (minimumArea + columns - 1) / columns)
        for rows in minimumRows...rowLimit {
            if let layout = fit(minimums: minimums, maximums: maximums, columns: columns, rows: rows, minimumArea: minimumArea) {
                return layout
            }
        }
        guard let fallbackTile, minimums.indices.contains(fallbackTile) else { return nil }
        var relaxed = maximums
        relaxed[fallbackTile] = nil
        let fallback = minimums[fallbackTile]
        let minimumFallbackArea = fallback.width * fallback.height
        for rows in minimumRows...rowLimit {
            let largest = minimumFallbackArea + rows * columns - minimumArea
            guard largest > minimumFallbackArea else { continue }
            for area in (minimumFallbackArea + 1)...largest {
                if let layout = fit(minimums: minimums, maximums: relaxed, columns: columns, rows: rows, minimumArea: minimumArea,
                                    areaLimit: (fallbackTile, area)) {
                    return layout
                }
            }
        }
        return nil
    }

    /// Fill the first open cell with each eligible footprint. Try the usual tile order before allowing moves across it.
    /// Equivalent tiles share a count in the search state, so swapping their identities cannot repeat a failed layout.
    private static func fit(minimums: [Size], maximums: [Size?], columns: Int, rows: Int, minimumArea: Int,
                            areaLimit: (tile: Int, cells: Int)? = nil) -> [Placement]? {
        let cells = rows * columns
        let choices = minimums.enumerated().map { index, minimum in
            let maximum = maximums[index]
            let width = min(columns, max(minimum.width, maximum?.width ?? columns))
            let height = min(rows, max(minimum.height, maximum?.height ?? rows))
            let budget: Int
            if let areaLimit, areaLimit.tile == index { budget = areaLimit.cells }
            else { budget = minimum.width * minimum.height + cells - minimumArea }
            var sizes: [Size] = []
            for span in minimum.width...width {
                let maxHeight = min(height, budget / span)
                guard maxHeight >= minimum.height else { continue }
                for length in minimum.height...maxHeight { sizes.append(Size(width: span, height: length)) }
            }
            return sizes.sorted {
                let a = $0.width * $0.height, b = $1.width * $1.height
                return a == b ? $0.width > $1.width : a < b
            }
        }

        var types: [[Size]] = []
        var counts: [Int] = []
        let tileTypes = choices.map { sizes in
            if let kind = types.firstIndex(of: sizes) {
                counts[kind] += 1
                return kind
            }
            types.append(sizes)
            counts.append(1)
            return types.count - 1
        }
        let maximumArea = choices.reduce(0) { sum, sizes in
            sum + (sizes.last.map { $0.width * $0.height } ?? 0)
        }
        let full = (1 << columns) - 1
        var masks = Array(repeating: 0, count: rows)
        var layout: [Placement?] = Array(repeating: nil, count: minimums.count)
        var failed = Set<SearchState>()

        func place(from start: Int, empty: Int, minimum: Int, maximum: Int, preservesOrder: Bool) -> Bool {
            guard minimum <= empty, empty <= maximum else { return false }
            if empty == 0 { return true }
            let state = SearchState(masks: masks, remaining: counts)
            guard failed.insert(state).inserted,
                  let row = (start..<rows).first(where: { masks[$0] != full }) else { return false }
            let column = (full ^ masks[row]).trailingZeroBitCount
            var tried = Set<Int>()
            for index in layout.indices where layout[index] == nil {
                let kind = tileTypes[index]
                guard tried.insert(kind).inserted, let largest = types[kind].last else { continue }
                let minLeft = minimum - minimums[index].width * minimums[index].height
                let maxLeft = maximum - largest.width * largest.height
                counts[kind] -= 1
                for size in types[kind] where column + size.width <= columns && row + size.height <= rows {
                    let mask = ((1 << size.width) - 1) << column
                    let covered = row..<row + size.height
                    guard covered.allSatisfy({ masks[$0] & mask == 0 }) else { continue }
                    for line in covered { masks[line] |= mask }
                    layout[index] = Placement(row: row, column: column, span: size.width, height: size.height)
                    if place(from: row, empty: empty - size.width * size.height, minimum: minLeft, maximum: maxLeft,
                             preservesOrder: preservesOrder) { return true }
                    layout[index] = nil
                    for line in covered { masks[line] &= ~mask }
                }
                counts[kind] += 1
                if preservesOrder { break }
            }
            return false
        }

        for preservesOrder in [true, false] {
            failed.removeAll(keepingCapacity: true)
            if place(from: 0, empty: cells, minimum: minimumArea, maximum: maximumArea, preservesOrder: preservesOrder) {
                return layout.compactMap { $0 }
            }
        }
        return nil
    }

    private struct SearchState: Hashable {
        var masks: [Int]
        var remaining: [Int]
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
