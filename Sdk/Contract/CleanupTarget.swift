import Foundation

/// A renewable cleanup choice. Its identity describes an operation, never the current scan's file identities.
/// Modules keep ownership, retention, running-app, cloud and helper checks in their existing handlers.
public struct CleanupTarget: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var bytes: UInt64
    public var action: Action
    public var automatic: Bool
    public var available: Bool
    public var defaultSelected: Bool
    public init(id: String, title: String, bytes: UInt64, action: Action, automatic: Bool = true, defaultSelected: Bool = false, available: Bool = true) {
        self.id = id; self.title = title; self.bytes = bytes; self.action = action
        self.automatic = automatic; self.defaultSelected = defaultSelected; self.available = available
    }
    public static func preferenceKey(scope: String = "cleanup", id: String) -> String {
        ((try? JSONEncoder().encode([scope, id])) ?? Data()).base64EncodedString()
    }
    public func isSelected(_ preferences: [String: Bool]) -> Bool {
        preferences[Self.preferenceKey(id: id)] ?? defaultSelected
    }
}

public extension Row {
    /// Convert a declared cleanup operation to a choice; utility actions remain attached to the row.
    func selectingCleanup(_ action: Action, bytes: UInt64, automatic: Bool = true, defaultSelected: Bool = false) -> Row {
        var row = self
        row.actions.removeAll { $0.id == action.id && $0.parameters == action.parameters }
        row.cleanup = CleanupTarget(id: row.id, title: row.title, bytes: bytes, action: action,
            automatic: automatic, defaultSelected: defaultSelected, available: row.activity == nil && !row.isFreeingInBackground)
        return row
    }
}

public extension Screen {
    /// All copies of a row (overview, groups and chart) keep the same choice identity.
    func mappingCleanup(_ transform: (Row) -> Row) -> Screen {
        func rows(_ values: [Row]) -> [Row] {
            values.map { original in
                var row = original; row.children = rows(row.children)
                return transform(row)
            }
        }
        func widgets(_ values: [ScreenWidget]) -> [ScreenWidget] {
            values.map { widget in
                switch widget {
                case var .list(list): list.rows = rows(list.rows); return .list(list)
                case var .section(section): section.widgets = widgets(section.widgets); return .section(section)
                case var .usage(usage):
                    for n in usage.segments.indices { usage.segments[n].items = rows(usage.segments[n].items) }
                    return .usage(usage)
                default: return widget
                }
            }
        }
        var screen = self; screen.widgets = widgets(screen.widgets)
        if screen.hero != nil {
            for n in screen.hero!.segments.indices { screen.hero!.segments[n].items = rows(screen.hero!.segments[n].items) }
        }
        return screen
    }
    func activeCleanupRow(for request: ActionRequest) -> Bool {
        var active = false
        _ = mappingCleanup { row in
            if (row.activity != nil || row.isFreeingInBackground), let action = row.cleanup?.action,
               action.id == request.actionID, action.parameters.allSatisfy({ request.parameters[$0.key] == $0.value }) { active = true }
            return row
        }
        return active
    }
    var cleanupTargets: [CleanupTarget] {
        var found: [String: CleanupTarget] = [:], order: [String] = []
        _ = mappingCleanup { row in
            if let target = row.cleanup, found[target.id] == nil { found[target.id] = target; order.append(target.id) }
            return row
        }
        return order.compactMap { found[$0] }
    }
}

public enum CleanupBatch {
    public static let actionID = "macspace.cleanupSelected"

    /// One guarded handler per selected operation. No newly discovered target is added to a frozen request.
    public static func run(_ targets: [CleanupTarget], automatic: Bool, context: ModuleContext,
                           progress: @escaping ProgressSink,
                           perform: @Sendable (ActionRequest, ModuleContext, @escaping ProgressSink) async -> ActionResult) async -> ActionResult {
        guard !targets.isEmpty else { return .init(outcome: .succeeded, message: "", refresh: false) }
        guard Set(targets.map(\.id)).count == targets.count, automatic || targets.allSatisfy(\.available) else {
            return .failed(String(localized: "Selected cleanup items changed. Review your selection again."))
        }
        let missing = targets.flatMap(\.action.requires).contains { context.permissions.status(of: $0) != .granted }
        if !automatic && missing { return .failed(String(localized: "Needs permission for the selected cleanup.")) }
        var details: [String] = [], finished: [String] = []
        var freed: UInt64 = 0, measured = false, failed = false, restart = false
        var presentation: ModulePresentation?
        var pending = false, completedAny = false
        for (index, target) in targets.enumerated() {
            if Task.isCancelled { failed = true; break }
            if automatic && (!target.available || !target.automatic) { continue }
            if automatic && target.action.requires.contains(where: { context.permissions.status(of: $0) != .granted }) {
                failed = true
                details.append(target.title + ": " + String(localized: "Needs permission for the selected cleanup."))
                continue
            }
            var parameters = target.action.parameters
            if automatic { parameters["automatic"] = "1" }
            let completed = finished
            let request = ActionRequest(actionID: target.action.id, parameters: parameters)
            let result = await perform(request, context) { update in
                progress(.init(fraction: (Double(index) + (update.fraction ?? 0)) / Double(targets.count), message: update.message, finished: completed))
            }
            if let value = result.freedBytes { measured = true; freed += value }
            failed = failed || result.outcome != .succeeded
            restart = restart || result.restartRequired
            details += [target.title + ": " + result.message] + result.details
            let inBackground = result.presentation?.screen.activeCleanupRow(for: request) == true
            pending = pending || inBackground
            if result.outcome == .succeeded && !inBackground { finished.append(target.id); completedAny = true }
            presentation = result.presentation ?? presentation
            progress(.init(fraction: Double(index + 1) / Double(targets.count), message: target.action.workingTitle ?? "", finished: finished))
        }
        return .init(outcome: failed ? .needsAttention : .succeeded,
            message: failed ? String(localized: "Some selected items could not be cleaned.") : pending && !completedAny ? "" : String(localized: "Cleaned selected items"),
            details: details, restartRequired: restart, freedBytes: measured ? freed : nil, presentation: presentation)
    }

    public static func automatic(screen: Screen, context: ModuleContext,
                                 perform: @Sendable (ActionRequest, ModuleContext, @escaping ProgressSink) async -> ActionResult) async -> CleanupReport? {
        let targets = screen.cleanupTargets.filter { $0.available && $0.automatic && $0.isSelected(context.cleanupChoices) }
        guard !targets.isEmpty else { return nil }
        let result = await run(targets, automatic: true, context: context, progress: { _ in }, perform: perform)
        return CleanupReport(freedBytes: result.freedBytes ?? 0, summary: targets.map(\.title).joined(separator: ", "), details: result.details)
    }
}
