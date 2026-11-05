import Foundation
import MacSpaceSdk
import MacSpaceDiskMapPrivileged

/// App selection freezes bundle identity before the data-review page is opened.
enum DiskUninstallBatch {
    enum Failure: Error { case ownership, running }
    static let reviewDestination = "uninstall-selected"
    static func plan(_ app: DiskApplication) -> AppRemovalPlan? {
        guard app.classification == .installedUser, app.removable, var plan = app.plan else { return nil }
        plan.targets = plan.targets.filter { $0.path == app.owner.path || $0.evidence.source == "startupItem" }
        guard plan.targets.filter({ $0.path == app.owner.path }).count == 1 else { return nil }
        // Startup plists are mandatory lifecycle work; app data remains optional.
        plan.catalogCandidates = [app.owner.path]
        return plan
    }
    static func resolve(_ plans: [AppRemovalPlan], apps: DiskApplications) -> [DiskApplication]? {
        guard !plans.isEmpty, plans.count <= 512, Set(plans.map { $0.owner.path }).count == plans.count else { return nil }
        var result: [DiskApplication] = []
        for reviewed in plans {
            guard reviewed.version == 1,
                  let app = apps.apps.first(where: { $0.owner.path == reviewed.owner.path }), let current = plan(app),
                  reviewed.owner == current.owner, reviewed.targets == current.targets, reviewed.startupItems == current.startupItems,
                  reviewed.targets.allSatisfy({ AppFileIdentity(path: $0.path) == $0.identity }) else { return nil }
            result.append(app)
        }
        return result
    }
    static func plans(parameters: [String: String], apps: DiskApplications) -> [AppRemovalPlan]? {
        let ids = Selection.ids(parameters["ids"])
        guard !ids.isEmpty, ids.count <= 512, Set(ids).count == ids.count,
              let text = parameters["reviewed"], text.utf8.count <= 1_048_576,
              let metadata = try? JSONDecoder().decode([String: String].self, from: Data(text.utf8)) else { return nil }
        let plans = ids.sorted().compactMap { id -> AppRemovalPlan? in
            guard let encoded = metadata[id], let plan = try? JSONDecoder().decode(AppRemovalPlan.self, from: Data(encoded.utf8)), plan.owner.path == id else { return nil }
            return plan
        }
        guard plans.count == ids.count, resolve(plans, apps: apps) != nil else { return nil }
        return plans
    }
    static func dataCandidates(_ selected: [DiskApplication], apps: DiskApplications, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> [DiskAppDataRemoval.Target] {
        let coverage = DiskAppDataRemoval.Coverage(apps: apps.apps)
        let candidates = selected.flatMap { DiskAppDataRemoval.candidates($0, coverage: coverage, home: home) }
        let unique = Dictionary(candidates.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        return AppOwnership.normalizedPaths(Array(unique.keys)).compactMap { unique[$0] }
    }
    /// Review keeps every original plan so rechecking an app never invents new targets.
    /// Only the app checkboxes included in this action may authorize bundle removal.
    static func selectedPlans(_ plans: [AppRemovalPlan], parameters: [String: String]) -> [AppRemovalPlan]? {
        guard !plans.isEmpty, plans.count <= 512, Set(plans.map { $0.owner.path }).count == plans.count else { return nil }
        guard parameters["selectApps"] == "1" else { return plans }
        let ids = Set(Selection.ids(parameters["ids"]))
        let selected = plans.filter { ids.contains($0.owner.path) }
        return selected.isEmpty ? nil : selected
    }
    static func validate(_ plans: [AppRemovalPlan], apps: DiskApplications, home: String, running: Set<String>) throws -> [DiskApplication] {
        guard let selected = resolve(plans, apps: apps) else { throw Failure.ownership }
        guard selected.allSatisfy({ !running.contains($0.owner.identifier) }) else { throw Failure.running }
        for plan in plans where AppRemovalExecutor.validate(plan: plan, catalog: apps.catalog, home: home) != nil { throw Failure.ownership }
        return selected
    }
}
