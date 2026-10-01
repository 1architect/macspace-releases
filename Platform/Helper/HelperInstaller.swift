import Foundation
import MacSpaceSdk
import ServiceManagement

/// Registers the helper launch daemon that ships in the app bundle (`Contents/Library/LaunchDaemons/com.macspace.helper.plist`,
/// program `Contents/MacOS/MacSpaceHelper`). Only meaningful from the signed app; the user approves it once in System Settings
/// > General > Login Items & Extensions.
public enum PrivilegedHelperInstaller {
    public static var service: SMAppService { .daemon(plistName: PrivilegedHelperConstants.launchDaemonPlistName) }

    public static var status: SMAppService.Status { service.status }

    /// What the Settings page shows for the "Privileged helper" permission.
    public static func permissionStatus(_ status: SMAppService.Status = PrivilegedHelperInstaller.status) -> PermissionStatus {
        switch status {
        case .enabled: return .granted
        case .notRegistered, .requiresApproval: return .missing
        case .notFound: return .unknown
        @unknown default: return .unknown
        }
    }

    /// Registers the daemon. `.requiresApproval` afterwards means the user must enable it in Login Items.
    public static func register() throws { try service.register() }

    public static func unregister() async throws { try await service.unregister() }

    public static func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }
}
