import Foundation
import Darwin
import MacSpacePlatform

public struct AppRemovalResult: Codable, Sendable {
    public var removed: [String]
    public var failures: [String: String]
}

/// The helper accepts an app identity, not an arbitrary list of paths. It recomputes every owned target itself.
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
        guard let path = arguments["app"], let owner = AppOwner(path: path), owner.identifier == arguments["identifier"],
              AppOwnership.removable(owner, home: home) else { throw PrivilegedOperationError("This app cannot be uninstalled.") }
        var st = stat()
        guard lstat(path, &st) == 0, st.st_uid == caller.uid || AdminAccounts.contains(caller.uid) else { throw PrivilegedOperationError("An administrator must remove this app.") }
        let result = AppRemovalExecutor.execute(owner: owner, installed: AppOwnership.installed(home: home), home: home, uid: caller.uid)
        return try JSONEncoder().encode(result)
    }
}

/// Shared with fixture tests. Live callers reach it only after the helper validates the app and requesting account.
public enum AppRemovalExecutor {
    public static func execute(owner: AppOwner, installed: [AppOwner], home: String, uid: uid_t = getuid(), systemLibrary: String = "/Library",
                               remove: (String) throws -> Void = { try FileManager.default.removeItem(atPath: $0) }) -> AppRemovalResult {
        guard AppOwnership.removable(owner, home: home) else { return AppRemovalResult(removed: [], failures: [owner.path: "This app cannot be uninstalled."]) }
        let path = owner.path
        let targets = AppOwnership.dataPaths(owner: owner, installed: installed, home: home, systemLibrary: systemLibrary) + [path]
        var result = AppRemovalResult(removed: [], failures: [:])
        for target in targets {
            if target == path, !result.failures.isEmpty { break }
            guard AppOwnership.safeExisting(target) else { continue }
            if target.hasSuffix(".plist"), target.contains("/LaunchAgents/") || target.contains("/LaunchDaemons/") {
                let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                process.arguments = ["bootout", target.contains("/LaunchDaemons/") ? "system" : "gui/\(uid)", target]
                process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                do { try process.run(); process.waitUntilExit() }
                catch { result.failures[target] = error.localizedDescription; continue }
            }
            do { try remove(target); result.removed.append(target) }
            catch { result.failures[target] = error.localizedDescription }
        }
        return result
    }
}
