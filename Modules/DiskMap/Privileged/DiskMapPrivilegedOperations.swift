import Foundation
import Darwin
import MacSpacePlatform

public struct AppRemovalResult: Codable, Sendable {
    public var removed: [String]
    public var failures: [String: String]
}

/// Executes only the exact reviewed plan. Missing, stale or expanded plans fail before any removal.
public struct DiskMapPrivilegedOperations: PrivilegedOperationHandler {
    public static let uninstall = "diskmap.uninstall"
    public init() {}
    public var operations: Set<String> { [Self.uninstall] }
    public func handle(_ operation: String, arguments: [String: String], caller: PrivilegedCaller) throws -> Data {
        var account = passwd(); var found: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 16384)
        guard operation == Self.uninstall, getpwuid_r(caller.uid, &account, &buffer, buffer.count, &found) == 0,
              found != nil, let dir = account.pw_dir else { throw PrivilegedOperationError("Unknown account or operation.") }
        let home = String(cString: dir)
        guard let encoded = arguments["plan"], encoded.utf8.count <= 1_048_576,
              let plan = try? JSONDecoder().decode(AppRemovalPlan.self, from: Data(encoded.utf8)),
              plan.owner.path == arguments["app"], plan.owner.identifier == arguments["identifier"] else {
            throw PrivilegedOperationError("A reviewed ownership plan is required.")
        }
        var st = stat()
        guard lstat(plan.owner.path, &st) == 0, st.st_uid == caller.uid || AdminAccounts.contains(caller.uid) else {
            throw PrivilegedOperationError("An administrator must remove this app.")
        }
        guard plan.catalogCandidates.count <= 4096,
              plan.catalogCandidates.allSatisfy({ $0.utf8.count <= 4096 && $0.hasSuffix(".app") && $0.hasPrefix("/") && URL(fileURLWithPath: $0).standardizedFileURL.path == $0 }) else {
            throw PrivilegedOperationError("Invalid reviewed catalog candidates.")
        }
        let catalog = AppOwnership.discover(home: home, candidates: plan.catalogCandidates + [plan.owner.path])
        let result = AppRemovalExecutor.execute(plan: plan, catalog: catalog, home: home, uid: caller.uid)
        return try JSONEncoder().encode(result)
    }
}

public enum AppRemovalExecutor {
    /// Pure preflight apart from read-only filesystem and signature checks; injectable catalog for fixtures.
    public static func validate(plan: AppRemovalPlan, catalog: AppCatalog, home: String, systemLibrary: String = "/Library") -> String? {
        guard plan.version == 1, let owner = AppOwner(path: plan.owner.path, knownIdentifiers: []), owner == plan.owner else {
            return "Application identity or signing metadata changed. Review a new plan."
        }
        guard AppOwnership.classification(owner, home: home, registered: catalog.registeredPaths, candidates: catalog.owners).0 == .installedUser else {
            return "This installation requires a different removal lifecycle."
        }
        guard owner.codeDirectoryDigest == nil || AppOwner.validSignature(owner.path) else {
            return "The selected app’s code signature is no longer valid."
        }
        // Never trust caller-supplied completeness, classifications, confidence or paths.
        let current = OwnershipResolver(catalog: catalog).plan(for: owner, home: home, systemLibrary: systemLibrary)
        guard plan.startupItems == current.startupItems else { return "Startup items changed. Review a new plan." }
        let startupPaths = Set(current.targets.filter { $0.evidence.source == "startupItem" }.map(\.path))
        guard startupPaths.isSubset(of: Set(plan.targets.map(\.path))) else { return "Reviewed startup items must be removed with the app." }
        guard !plan.targets.isEmpty, plan.targets.count <= 4096,
              Set(plan.targets.map(\.path)).count == plan.targets.count,
              plan.targets.contains(where: { $0.path == owner.path }),
              AppOwnership.normalizedPaths(plan.targets.map(\.path)) == plan.targets.map(\.path).sorted() else {
            return "Invalid or overlapping reviewed targets."
        }
        for target in plan.targets {
            guard current.targets.contains(target), AppFileIdentity(path: target.path) == target.identity else {
                return "A reviewed target's identity or ownership changed. Review a new plan."
            }
        }
        return nil
    }
    public static func execute(plan: AppRemovalPlan, catalog: AppCatalog, home: String, systemLibrary: String = "/Library", uid: uid_t = getuid(),
                               stopStartup: (([AppStartupItem]) throws -> Void)? = nil,
                               remove: ((String) throws -> Void)? = nil) -> AppRemovalResult {
        if let error = validate(plan: plan, catalog: catalog, home: home, systemLibrary: systemLibrary) {
            return AppRemovalResult(removed: [], failures: [plan.owner.path: error])
        }
        var result = AppRemovalResult(removed: [], failures: [:])
        // Pin every target and its descendants before stopping services or removing any data.
        let targets = plan.targets.filter { $0.path != plan.owner.path } + plan.targets.filter { $0.path == plan.owner.path }
        let guarded: ReviewedDirectoryRemoval.Plan?
        do {
            guarded = try remove == nil ? ReviewedDirectoryRemoval.prepareAuthorized(targets.map { target in
                let identity = target.identity
                return .init(path: target.path, expected: .init(device: identity.device, inode: identity.inode, uid: identity.uid,
                                                              modifiedSeconds: identity.modifiedSeconds, modifiedNanos: identity.modifiedNanos))
            }, home: home, uid: uid) : nil
            if let stopStartup { try stopStartup(plan.startupItems ?? []) }
            else { try AppStartupItems.stop(plan.startupItems ?? [], uid: uid) }
        } catch { return AppRemovalResult(removed: [], failures: [plan.owner.path: error.localizedDescription]) }
        // Data first, bundle last. Preflight verified every target before any side effect.
        for (index, target) in targets.enumerated() {
            guard result.failures.isEmpty else { break }
            guard AppFileIdentity(path: target.path) == target.identity else {
                result.failures[target.path] = "Target changed after review."; break
            }
            do {
                if let remove { try remove(target.path) }
                else { try guarded!.remove(at: index) }
                result.removed.append(target.path)
            }
            catch { result.failures[target.path] = error.localizedDescription }
        }
        return result
    }
    /// Legacy source compatibility only: execution can no longer invent an unreviewed plan.
    public static func execute(owner: AppOwner, installed: [AppOwner], home: String, uid: uid_t = getuid(), systemLibrary: String = "/Library",
                               remove: (String) throws -> Void = { try FileManager.default.removeItem(atPath: $0) }) -> AppRemovalResult {
        AppRemovalResult(removed: [], failures: [owner.path: "A reviewed ownership plan is required."])
    }
}
