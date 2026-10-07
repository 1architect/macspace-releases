import Foundation

/// Something a module needs from the user before it can work fully. Modules declare these in their manifest;
/// the app shows them on the module's settings page and asks the user, so a module never prompts on its own.
public enum Permission: String, Codable, CaseIterable, Sendable {
    /// Full Disk Access for the app, needed to read protected locations.
    case fullDiskAccess
    /// The privileged helper (a launch daemon the user approves once) for steps that need root.
    case privilegedHelper
    /// The MacSpace configuration profile, which the user approves in System Settings.
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
        case .fullDiskAccess: return "Needed to measure everything on the disk."
        case .privilegedHelper: return "Does the few things that need an administrator."
        case .configurationProfile: return "Applies the Debloat policies you turn on."
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
