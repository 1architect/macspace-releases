import Foundation
import MacSpacePlatform

public extension DebloatTargetUser {
    /// The account behind a uid, e.g. the client of an XPC connection.
    static func forUID(_ uid: uid_t) -> DebloatTargetUser? {
        guard let entry = getpwuid(uid), let name = entry.pointee.pw_name.map({ String(cString: $0) }),
              let dir = entry.pointee.pw_dir.map({ String(cString: $0) }) else { return nil }
        return DebloatTargetUser(name: name, uid: uid, home: URL(fileURLWithPath: dir))
    }
}

/// The Debloat module's root-level operations, compiled into the helper. They take control identifiers and flags only, so a
/// client can do nothing beyond what the built-in catalog defines.
public struct DebloatPrivilegedOperations: PrivilegedOperationHandler {
    public static let status = "debloat.status"
    public static let apply = "debloat.apply"
    public static let revert = "debloat.revert"
    /// Removes the MacSpace profile once no policy remains in it. Takes no arguments: it can only remove that one profile.
    public static let removeProfile = "debloat.removeProfile"

    private let engineFactory: @Sendable (DebloatTargetUser?) -> DebloatEngine

    public init(engineFactory: @escaping @Sendable (DebloatTargetUser?) -> DebloatEngine = { user in
        DebloatEngine(system: LiveDebloatSystem(targetUser: user), journal: DebloatJournalStore(targetUser: user))
    }) {
        self.engineFactory = engineFactory
    }

    public var operations: Set<String> { [Self.status, Self.apply, Self.revert, Self.removeProfile] }

    public static func arguments(controlIDs: [String], options: DebloatPlanOptions) -> [String: String] {
        ["controls": controlIDs.joined(separator: ","),
         "restoreFallbacks": String(options.restoreFallbacks), "immediate": String(options.immediate)]
    }

    public func handle(_ operation: String, arguments: [String: String], caller: PrivilegedCaller) throws -> Data {
        let engine = engineFactory(DebloatTargetUser.forUID(caller.uid))
        if operation == Self.removeProfile { return Data(try engine.system.removeProfile().utf8) }
        let ids = (arguments["controls"] ?? "").split(separator: ",").map(String.init)
        let unknown = ids.filter { id in !engine.controls.contains { $0.id == id } }
        guard unknown.isEmpty else { throw PrivilegedOperationError("Unknown control(s): \(unknown.joined(separator: ", ")).") }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        switch operation {
        case Self.status:
            let controls = ids.isEmpty ? engine.controls : engine.controls.filter { ids.contains($0.id) }
            return try encoder.encode(controls.map(engine.status(of:)))
        case Self.apply, Self.revert:
            guard !ids.isEmpty else { throw PrivilegedOperationError("Name at least one control.") }
            let options = DebloatPlanOptions(restoreFallbacks: arguments["restoreFallbacks"] == "true",
                                             immediate: arguments["immediate"] == "true", privilegeFilter: .root)
            let plans = try engine.plan(operation == Self.apply ? .apply : .revert, controlIDs: ids, options: options)
            return try encoder.encode(engine.execute(plans))
        default:
            throw PrivilegedOperationError("Unknown operation \(operation).")
        }
    }
}
