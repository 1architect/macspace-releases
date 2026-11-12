import MacSpaceSdk
import SwiftUI

/// Progress, hover and footer animation updates reuse the content projection. Keep
/// only the current inputs per form, so old inventories and widths cannot accumulate.
@MainActor
final class WidgetPresentationCache {
    struct Fitting: Equatable {
        var height: CGFloat
        var rowTops: [String: CGFloat]
        var scrollTop: CGFloat
        var bottomRoom: CGFloat
    }
    private struct Input: Equatable {
        var widgets: [ScreenWidget]
        var checked: Set<String>
        var width: Double
        var expandsGroups: Bool
        var fitting: Fitting
    }
    struct Value {
        var items: [ModulePagePresentation.Item]
        var ids: [String]
        var positions: [String: Int]
    }
    private var input: Input?
    private var cached: Value?
    private(set) var computations = 0

    func value(widgets: [ScreenWidget], checked: Set<String>, width: Double, expandsGroups: Bool,
               fitting: Fitting, fit: (ScreenWidget) -> ScreenWidget) -> Value {
        let next = Input(widgets: widgets, checked: checked, width: width, expandsGroups: expandsGroups, fitting: fitting)
        if input == next, let cached { return cached }
        let visible = ModulePagePresentation.visibleWidgets(widgets, checked: checked)
        let items = ModulePagePresentation.items(visible, width: width, expandsGroups: expandsGroups)
        let ids = WidgetForm<EmptyView>.itemIDs(items.flatMap(\.widgets).map(fit))
        let value = Value(items: items, ids: ids, positions: Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first }))
        input = next; cached = value; computations += 1
        return value
    }
}
