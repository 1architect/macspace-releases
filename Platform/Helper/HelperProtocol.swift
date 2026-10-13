import Darwin.membership
import Foundation

/// The privileged helper is a launch daemon (registered with `SMAppService`) that runs the few steps that need root.
///
/// It exposes **named operations**, never commands or paths: each module's `Privileged` library contributes the handlers
/// for its own operations, compiled into the helper, so nothing installed later can ask the helper to do more. Clients must
/// satisfy a code-signing requirement, which is covered by the app's signature.
public enum PrivilegedHelperConstants {
    public static let machServiceName = "com.macspace.helper"
    public static let launchDaemonPlistName = "com.macspace.helper.plist"
    public static let protocolVersion = 1
    public static let helperVersion = "1"
}

@objc public protocol MacSpaceHelperProtocol {
    /// `request` is a JSON-encoded `HelperRequest`; the reply is a JSON-encoded `HelperResponse`.
    func perform(_ request: Data, withReply reply: @escaping (Data) -> Void)
}

public struct HelperRequest: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var operation: String
    public var arguments: [String: String]

    public init(operation: String, arguments: [String: String] = [:], protocolVersion: Int = PrivilegedHelperConstants.protocolVersion) {
        self.protocolVersion = protocolVersion
        self.operation = operation
        self.arguments = arguments
    }
}

public struct HelperResponse: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var helperVersion: String
    public var error: String?
    /// The operation's result, encoded by its handler (JSON by convention).
    public var payload: Data?

    public init(error: String? = nil, payload: Data? = nil) {
        self.protocolVersion = PrivilegedHelperConstants.protocolVersion
        self.helperVersion = PrivilegedHelperConstants.helperVersion
        self.error = error
        self.payload = payload
    }
}

/// Who is calling: the user behind the XPC connection. Handlers act for this user's home, never for root's.
public struct PrivilegedCaller: Sendable, Equatable {
    public var uid: uid_t

    public init(uid: uid_t) { self.uid = uid }
}

public struct PrivilegedOperationError: Error, LocalizedError, Equatable {
    public var message: String

    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Handles a set of operations. A module's `Privileged` library provides one.
public protocol PrivilegedOperationHandler: Sendable {
    /// Operation identifiers, namespaced by module (`siri.orphan-subscriptions.plan`).
    var operations: Set<String> { get }
    /// The operations that only read the Mac, which any account may ask for. Every other one changes or deletes something for the
    /// whole Mac and is run only for an administrator (`PrivilegedHelperService`), so an operation added later is protected unless
    /// its module says otherwise.
    var readOnlyOperations: Set<String> { get }
    func handle(_ operation: String, arguments: [String: String], caller: PrivilegedCaller) throws -> Data
}

public extension PrivilegedOperationHandler {
    var readOnlyOperations: Set<String> { [] }
}

/// Whether an account is an administrator of this Mac (a member of the `admin` group, nested groups included).
public enum AdminAccounts {
    public static let adminGroupID: gid_t = 80

    public static func contains(_ uid: uid_t) -> Bool {
        if uid == 0 { return true }
        var user = uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        var group = user
        guard mbr_uid_to_uuid(uid, &user) == 0, mbr_gid_to_uuid(adminGroupID, &group) == 0 else { return false }
        var member: Int32 = 0
        guard mbr_check_membership(&user, &group, &member) == 0 else { return false }
        return member != 0
    }
}

public enum PrivilegedHelperError: LocalizedError, Equatable, CustomStringConvertible {
    case connection(String)
    /// The helper took the call and never answered: launchd could not start it (its signature no longer matches the one approved).
    /// Asking again does not help, so a channel stops asking for a while (`LazyPrivilegedChannel`).
    case noAnswer(seconds: Int)
    case malformedResponse
    case helper(String)

    public var errorDescription: String? { description }

    public var description: String {
        switch self {
        case let .connection(message): return "Could not reach the MacSpace helper: \(message)"
        case let .noAnswer(seconds): return "Could not reach the MacSpace helper: no answer after \(seconds) seconds"
        case .malformedResponse: return "The MacSpace helper sent an unreadable response."
        case let .helper(message): return message
        }
    }
}

enum HelperCoding {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
