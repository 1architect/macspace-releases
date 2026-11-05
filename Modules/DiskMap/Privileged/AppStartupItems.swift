import Foundation
import Darwin
import MacSpacePlatform

/// Frozen launchd metadata. A label alone never establishes ownership: the executable
/// must be inside this installation or match its uniquely declared, signed helper.
public struct AppStartupItem: Codable, Equatable, Sendable {
    public var path: String
    public var identity: AppFileIdentity
    public var label: String
    public var executable: String
    public var executableIdentity: AppFileIdentity
    public var system: Bool
}

public enum AppStartupItems {
    public static func discover(owner: AppOwner, catalog: AppCatalog, home: String, systemLibrary: String = "/Library") -> [AppStartupItem] {
        var items: [AppStartupItem] = []
        let roots = [(home + "/Library/LaunchAgents", false), (systemLibrary + "/LaunchAgents", false),
                     (systemLibrary + "/LaunchDaemons", true), (owner.path + "/Contents/Library/LaunchAgents", false),
                     (owner.path + "/Contents/Library/LaunchDaemons", true)]
        for (root, system) in roots {
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).sorted().prefix(8192)
            for name in names where name.hasSuffix(".plist") {
                let path = root + "/" + name
                guard let info = propertyList(path), let label = info["Label"] as? String,
                      AppOwner.validIdentifier(label), !label.hasPrefix("com.apple.") else { continue }
                let program: String?
                if path.hasPrefix(owner.path + "/"), let relative = info["BundleProgram"] as? String,
                   !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") {
                    program = owner.path + "/" + relative
                } else { program = info["Program"] as? String ?? (info["ProgramArguments"] as? [String])?.first }
                guard let program, ownsExecutable(program, owner: owner, catalog: catalog, systemLibrary: systemLibrary),
                      let identity = AppFileIdentity(path: path), let executableIdentity = AppFileIdentity(path: program) else { continue }
                items.append(.init(path: path, identity: identity, label: label, executable: program, executableIdentity: executableIdentity, system: system))
            }
        }
        // SMLoginItem helpers are embedded apps rather than standalone launchd plists.
        let loginRoot = owner.path + "/Contents/Library/LoginItems"
        for name in ((try? FileManager.default.contentsOfDirectory(atPath: loginRoot)) ?? []).sorted().prefix(1024) where name.hasSuffix(".app") {
            let path = loginRoot + "/" + name + "/Contents/Info.plist"
            guard let info = propertyList(path), let label = info["CFBundleIdentifier"] as? String,
                  AppOwner.validIdentifier(label), !label.hasPrefix("com.apple."),
                  let binary = info["CFBundleExecutable"] as? String, !binary.isEmpty, !binary.contains("/"),
                  let identity = AppFileIdentity(path: path) else { continue }
            let program = loginRoot + "/" + name + "/Contents/MacOS/" + binary
            guard ownsExecutable(program, owner: owner, catalog: catalog, systemLibrary: systemLibrary),
                  let executableIdentity = AppFileIdentity(path: program) else { continue }
            items.append(.init(path: path, identity: identity, label: label, executable: program, executableIdentity: executableIdentity, system: false))
        }
        return items.sorted { $0.path < $1.path }
    }

    private static func propertyList(_ path: String) -> [String: Any]? {
        var info = stat()
        guard AppOwnership.safeExisting(path), lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size <= 1_048_576, info.st_flags & UInt32(SF_DATALESS | SF_RESTRICTED | SF_IMMUTABLE | UF_IMMUTABLE) == 0,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    private static func ownsExecutable(_ path: String, owner: AppOwner, catalog: AppCatalog, systemLibrary: String) -> Bool {
        var info = stat()
        guard AppOwnership.safeExisting(path), lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return false }
        if path.hasPrefix(owner.path + "/") { return true }
        let id = (path as NSString).lastPathComponent
        guard path == systemLibrary + "/PrivilegedHelperTools/" + id, let requirement = owner.helpers[id],
              catalog.owners.filter({ $0.helpers[id] != nil }).map(\.path) == [owner.path] else { return false }
        return AppOwner.helperMatches(path, requirement: requirement, team: owner.team)
    }

    /// Verify the loaded job's executable before using its label. A forged plist must
    /// never let an app boot out an unrelated job. Missing jobs need no lifecycle work.
    public static func stop(_ items: [AppStartupItem], uid: uid_t, runner: any CommandRunning = ProcessCommandRunner(defaultTimeout: 10)) throws {
        for item in items {
            guard AppFileIdentity(path: item.path) == item.identity,
                  AppFileIdentity(path: item.executable) == item.executableIdentity else { throw CocoaError(.fileReadUnknown) }
            for domain in item.system ? ["system"] : ["gui/\(uid)", "user/\(uid)"] {
                let service = domain + "/" + item.label
                let status = try runner.run("/bin/launchctl", ["print", service])
                if status.exitCode == 113 || status.exitCode == 3 { continue }
                guard status.exitCode == 0 else { throw failure(status, service: service) }
                let lines = String(decoding: status.stdout, as: UTF8.self).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                guard lines.contains("program = " + item.executable) else { throw CocoaError(.fileReadUnknown) }
                let removed = try runner.run("/bin/launchctl", ["bootout", service])
                guard removed.exitCode == 0 || removed.exitCode == 113 || removed.exitCode == 3 else { throw failure(removed, service: service) }
            }
        }
    }

    private static func failure(_ result: CommandResult, service: String) -> CommandRunnerError {
        .nonZeroExit(executable: "/bin/launchctl", arguments: [service], code: result.exitCode, stderr: String(decoding: result.stderr, as: UTF8.self))
    }
}
