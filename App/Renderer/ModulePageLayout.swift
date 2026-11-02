import CoreGraphics

/// Module content responds to its available width, independently of the window's presentation mode.
/// Three columns fit a large/full-screen window; smaller displays keep controls readable in fewer columns.
enum ModulePageLayout {
    static let gap: CGFloat = 24
    static let minimumColumnWidth: CGFloat = 420
    static let maximumColumnWidth: CGFloat = 520
    static let maximumSingleColumnWidth: CGFloat = 820

    struct Metrics: Equatable {
        let columns: Int
        let contentWidth: CGFloat
        var columnWidth: CGFloat { (contentWidth - CGFloat(columns - 1) * ModulePageLayout.gap) / CGFloat(columns) }
    }

    /// Width is the space inside the existing page margins. A drill-down list opts into one column.
    static func metrics(availableWidth: CGFloat, maximumColumns: Int = 3) -> Metrics {
        let width = availableWidth.isFinite ? max(0, availableWidth) : maximumSingleColumnWidth
        let limit = min(3, max(1, maximumColumns))
        // At full screen the reference uses about 80% of the window. Half/quarter windows
        // keep the compact 30-point margins, reclaiming room before dropping a column.
        let canvasWidth = limit == 1 ? min(width, maximumSingleColumnWidth)
            : min(width, max(maximumSingleColumnWidth, (width + 2 * PageInsets.side) * 0.8))
        let columns = (1...limit).reversed().first {
            canvasWidth >= CGFloat($0) * minimumColumnWidth + CGFloat($0 - 1) * gap
        } ?? 1
        let maximumWidth = columns == 1 ? maximumSingleColumnWidth
            : CGFloat(columns) * maximumColumnWidth + CGFloat(columns - 1) * gap
        return Metrics(columns: columns, contentWidth: min(canvasWidth, maximumWidth))
    }

    struct GraphArrangement: Equatable {
        let contentWidth: CGFloat
        let listWidth: CGFloat
        let graphWidth: CGFloat
        let graphHeight: CGFloat
    }

    static let minimumSideListWidth: CGFloat = 440
    static let minimumSideGraphWidth: CGFloat = 420
    static var minimumSideViewportWidth: CGFloat {
        2 * PageInsets.side + minimumSideListWidth + gap + minimumSideGraphWidth
    }

    /// Switch only when both sides have useful room. Slightly enlarged floating windows
    /// still use the stacked layout; increasing height alone cannot enable two sides.
    static func graphArrangement(viewport: CGSize, hasGraph: Bool) -> GraphArrangement? {
        guard hasGraph, viewport.width.isFinite, viewport.height.isFinite,
              viewport.width >= minimumSideViewportWidth else { return nil }
        let width = max(0, viewport.width - 2 * PageInsets.side)
        // A readable list at the left; the graph gets the remaining room, as in the reference.
        let list = min(maximumSingleColumnWidth, max(minimumSideListWidth, width * 0.34))
        let graph = max(0, width - gap - list)
        let height = sideGraphHeight(width: graph, viewportHeight: viewport.height)
        return GraphArrangement(contentWidth: width, listWidth: list, graphWidth: graph, graphHeight: height)
    }

    static func sideGraphHeight(width: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        min(max(150, viewportHeight - PageInsets.scrollTop - PageInsets.footer - 120), max(220, width * 0.5))
    }

    /// Storage charts gain useful height inside a narrow overview column, without growing with window height.
    static func chartHeight(width: CGFloat, columns: Int) -> CGFloat {
        width <= maximumSingleColumnWidth ? 150 : min(390, width * 0.245)
    }
}
