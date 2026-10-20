import MacSpaceSdk

extension Screen {
    /// A foreground result can hand the same action to a row's background work (`Row.activity`, `Badge.freeingInBackground`). Match its parameters as well as its id:
    /// work on another cloud folder or another target must not suppress this action's result or completion.
    func activeRow(for request: ActionRequest) -> Row? {
        func find(_ rows: [Row]) -> Row? {
            for row in rows {
                if row.activity != nil || row.isFreeingInBackground, row.actions.contains(where: { $0.id == request.actionID && $0.parameters == request.parameters }) { return row }
                if let found = find(row.children) { return found }
            }
            return nil
        }
        func widgets(_ values: [ScreenWidget]) -> Row? {
            for widget in values {
                switch widget {
                case let .list(list): if let found = find(list.rows) { return found }
                case let .section(section): if let found = widgets(section.widgets) { return found }
                case let .usage(usage): if let found = find(usage.segments.compactMap(\.group)) { return found }
                default: break
                }
            }
            return nil
        }
        return widgets(self.widgets) ?? find(hero?.segments.compactMap(\.group) ?? [])
    }
}
