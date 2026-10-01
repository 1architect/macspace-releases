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
    func handle(_ operation: String, arguments: [String: String], caller: PrivilegedCaller) throws -> Data
}

public enum PrivilegedHelperError: LocalizedError, Equatable, CustomStringConvertible {
    case connection(String)
    case malformedResponse
    case helper(String)

    public var errorDescription: String? { description }

    public var description: String {
        switch self {
        case let .connection(message): return "Could not reach the MACSPACE helper: \(message)"
        case .malformedResponse: return "The MACSPACE helper sent an unreadable response."
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
