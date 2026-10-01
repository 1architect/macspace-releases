import Foundation

/// Something a module needs from the user before it can work fully. Modules declare these in their manifest;
/// the app shows them on the module's settings page and asks the user, so a module never prompts on its own.
public enum Permission: String, Codable, CaseIterable, Sendable {
    /// Full Disk Access for the app, needed to read protected locations.
    case fullDiskAccess
    /// The privileged helper (a launch daemon the user approves once) for steps that need root.
    case privilegedHelper
    /// The MACSPACE configuration profile, which the user approves in System Settings.
    case configurationProfile

    public var title: String {
        switch self {
        case .fullDiskAccess: return "Full Disk Access"
        case .privilegedHelper: return "Privileged helper"
        case .configurationProfile: return "Configuration profile"
        }
    }

    public var detail: String {
        switch self {
        case .fullDiskAccess: return "Lets MACSPACE read protected system locations to measure them."
        case .privilegedHelper: return "A background service you approve once, for the few steps that need administrator rights."
        case .configurationProfile: return "A profile you approve in System Settings that enforces the privacy policies you choose."
        }
    }
}

public enum PermissionStatus: String, Codable, Sendable {
    case granted
    case missing
    /// The state cannot be read (for example the helper is not installed in a development build).
    case unknown
}

public protocol PermissionChecker: Sendable {
    func status(of permission: Permission) -> PermissionStatus
}
