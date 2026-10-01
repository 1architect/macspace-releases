import Foundation
import MacSpaceSdk

/// Reads the real state of the permissions modules ask for.
public struct LivePermissionChecker: PermissionChecker {
    public typealias Probe = @Sendable () -> PermissionStatus

    private let helper: Probe
    private let profile: Probe
    private let fullDiskAccess: Probe

    /// `helper` and `profile` are supplied by the parts of the app that own them; until then they read as unknown.
    public init(helper: @escaping Probe = { .unknown }, profile: @escaping Probe = { .unknown },
                fullDiskAccess: @escaping Probe = LivePermissionChecker.probeFullDiskAccess) {
        self.helper = helper
        self.profile = profile
        self.fullDiskAccess = fullDiskAccess
    }

    public func status(of permission: Permission) -> PermissionStatus {
        switch permission {
        case .fullDiskAccess: return fullDiskAccess()
        case .privilegedHelper: return helper()
        case .configurationProfile: return profile()
        }
    }

    /// Full Disk Access cannot be asked for directly. A protected file that exists on every Mac and opens only with the
    /// permission is the reliable probe (the TCC database stays closed even with it, measured on macOS 27).
    public static func probeFullDiskAccess() -> PermissionStatus {
        let path = "/private/var/db/os_eligibility/eligibility.plist"
        guard FileManager.default.fileExists(atPath: path) else { return .unknown }
        guard let handle = FileHandle(forReadingAtPath: path) else { return .missing }
        try? handle.close()
        return .granted
    }

    public static let fullDiskAccessSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
}
