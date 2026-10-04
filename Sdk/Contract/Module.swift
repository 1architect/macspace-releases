import Foundation

public struct ActionRequest: Codable, Equatable, Sendable {
    public var actionID: String
    public var parameters: [String: String]

    public init(actionID: String, parameters: [String: String] = [:]) {
        self.actionID = actionID
        self.parameters = parameters
    }
}

public struct ActionProgress: Codable, Equatable, Sendable {
    /// 0...1, or nil when the length is unknown.
    public var fraction: Double?
    public var message: String

    public init(fraction: Double? = nil, message: String) {
        self.fraction = fraction
        self.message = message
    }
}

public typealias ProgressSink = @Sendable (ActionProgress) -> Void

public struct ActionResult: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case succeeded
        case failed
        /// Nothing failed, but the user has to do something (approve a profile, restart).
        case needsAttention
    }

    public var outcome: Outcome
    public var message: String
    public var details: [String]
    /// Ask the app to fetch the screen again.
    public var refresh: Bool
    public var restartRequired: Bool
    /// Space the action freed, measured on the volume, when it cleaned something. The app adds it to the cleanup history.
    public var freedBytes: UInt64?

    public init(outcome: Outcome, message: String, details: [String] = [], refresh: Bool = true, restartRequired: Bool = false,
                freedBytes: UInt64? = nil) {
        self.outcome = outcome
        self.message = message
        self.details = details
        self.refresh = refresh
        self.restartRequired = restartRequired
        self.freedBytes = freedBytes
    }

    public static func succeeded(_ message: String, details: [String] = [], restartRequired: Bool = false, freedBytes: UInt64? = nil) -> ActionResult {
        ActionResult(outcome: .succeeded, message: message, details: details, restartRequired: restartRequired, freedBytes: freedBytes)
    }

    public static func failed(_ message: String, details: [String] = []) -> ActionResult {
        ActionResult(outcome: .failed, message: message, details: details, refresh: false)
    }
}

/// What an automatic cleanup did (`MacSpaceModule.autoClean`).
public struct CleanupReport: Codable, Equatable, Sendable {
    /// Space freed, measured on the volume.
    public var freedBytes: UInt64
    /// One line: what was cleaned ("caches and old reports").
    public var summary: String
    public var details: [String]

    public init(freedBytes: UInt64, summary: String, details: [String] = []) {
        self.freedBytes = freedBytes
        self.summary = summary
        self.details = details
    }
}

/// Root-level operations go through the app's privileged helper, which accepts only operation identifiers declared by
/// a module's `Privileged` library compiled into it.
public protocol PrivilegedChannel: Sendable {
    func perform(operation: String, arguments: [String: String]) async throws -> Data
}

public struct ModuleContext: Sendable {
    public var manifest: ModuleManifest
    public var options: any OptionStore
    public var permissions: any PermissionChecker
    /// nil when the helper is not installed or the user has not approved it.
    public var privileged: (any PrivilegedChannel)?

    public init(manifest: ModuleManifest, options: any OptionStore, permissions: any PermissionChecker,
                privileged: (any PrivilegedChannel)? = nil) {
        self.manifest = manifest
        self.options = options
        self.permissions = permissions
        self.privileged = privileged
    }
}

/// A feature area of MacSpace. It describes what the user sees (`Screen`) and does what the user asks (`perform`);
/// the app owns all drawing, navigation and settings. Calls arrive off the main thread and may take seconds.
public protocol MacSpaceModule: Sendable {
    init()

    /// The module's tile on the dashboard.
    func tile(context: ModuleContext) async -> Tile

    /// The module's full page.
    func screen(context: ModuleContext) async -> Screen

    func perform(_ request: ActionRequest, context: ModuleContext, progress: @escaping ProgressSink) async -> ActionResult

    /// Runs a task declared in the manifest's `backgroundTasks`.
    func runBackgroundTask(_ id: String, context: ModuleContext) async

    /// The user pressed Refresh: drop anything cached so the next `tile` and `screen` read the system again.
    func invalidate() async

    /// Automatic cleanup, run in the background from time to time when the user turned it on in Settings: free what is safe to free
    /// without asking (what the page's main Clean action frees, never anything that cannot be undone or needs a decision). nil
    /// when there was nothing to do. A module that takes part declares `autoClean` in its manifest.
    func autoClean(context: ModuleContext) async -> CleanupReport?
}

public extension MacSpaceModule {
    func invalidate() async {}

    func autoClean(context: ModuleContext) async -> CleanupReport? { nil }

    func runBackgroundTask(_ id: String, context: ModuleContext) async {}
}

/// The principal class of a module bundle. The app loads the bundle, instantiates this class and asks it for the module.
/// Subclass it with an `@objc(...)` name and set that name as the bundle's `NSPrincipalClass`.
open class MacSpaceModuleEntry: NSObject, @unchecked Sendable {
    public required override init() { super.init() }

    open func makeModule() -> any MacSpaceModule {
        fatalError("MacSpaceModuleEntry.makeModule() must be overridden")
    }
}
