import CoreGraphics

/// Module content responds to its available width, independently of the window's presentation mode.
/// Three columns fit a large/full-screen window; smaller displays keep controls readable in fewer columns.
enum ModulePageLayout {
    static let gap: CGFloat = 24
    static let minimumColumnWidth: CGFloat = 420
    static let maximumColumnWidth: CGFloat = 480
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
        let columns = (1...limit).reversed().first {
            width >= CGFloat($0) * minimumColumnWidth + CGFloat($0 - 1) * gap
        } ?? 1
        let maximumWidth = columns == 1 ? maximumSingleColumnWidth
            : CGFloat(columns) * maximumColumnWidth + CGFloat(columns - 1) * gap
        return Metrics(columns: columns, contentWidth: min(width, maximumWidth))
    }

    /// Storage charts gain useful height inside a narrow overview column, without growing with window height.
    static func chartHeight(width: CGFloat, columns: Int) -> CGFloat {
        columns == 1 ? 150 : min(240, max(180, width * 0.55))
    }
}
