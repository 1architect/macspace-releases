import CoreServices
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

    /// Tells Launch Services about this app. A copy that arrived without Launch Services noticing (a shared folder, a VM, a manual
    /// copy) leaves the helper "not found" and registering fails; once the app is registered, the status becomes "requires approval".
    public static func registerAppWithLaunchServices(bundle: Bundle = .main) {
        _ = LSRegisterURL(bundle.bundleURL as CFURL, true)
    }

    public struct NotInApplicationsError: LocalizedError {
        public let path: String
        public var errorDescription: String? {
            "MacSpace runs from \(path). Install the helper from the copy in an Applications folder: macOS ties the helper to the copy it was installed from, and a build folder is replaced by every build."
        }
    }

    /// Whether the app sits in an Applications folder (/Applications or ~/Applications), the only place the helper is installed from.
    public static func isInApplicationsFolder(_ path: String) -> Bool {
        path.hasPrefix("/Applications/") || path.contains("/Applications/")
    }

    /// Registers the daemon. `.requiresApproval` afterwards means the user must enable it in Login Items. Refused from a copy outside
    /// an Applications folder: registered from the build folder, the helper stayed tied to that copy, every build replaced it, and
    /// installing from the real copy failed with "Codesigning failure loading plist" (-67056).
    public static func register(bundle: Bundle = .main) throws {
        guard isInApplicationsFolder(bundle.bundlePath) else { throw NotInApplicationsError(path: bundle.bundlePath) }
        if status == .notFound { registerAppWithLaunchServices() }
        try service.register()
    }

    public static func unregister() async throws { try await service.unregister() }

    /// Checks at launch that the approved helper answers, without ever costing the user their approval.
    ///
    /// Unregistering and registering again drops the approval: the app used to do that whenever the running helper was from an
    /// earlier build or did not answer at once, and every new build had to be approved again (and System Data warned until it was).
    /// Now a helper from an earlier build steps down by itself (`HelperLifecycle`), and launchd starts the current one on the next
    /// request, which this check makes. Only a helper that never answers, over several tries, is registered again: the job is then
    /// not loaded at all, and registering is the only way back. Returns whether it was re-registered.
    @discardableResult
    public static func restartIfStale(channel: any PrivilegedChannel, bundle: Bundle = .main,
                                      waits: [Double] = [0, 1, 3, 6]) async -> Bool {
        guard status == .enabled, let helperPath = bundle.executableURL?.deletingLastPathComponent().appendingPathComponent("MacSpaceHelper").path,
              let onDisk = HelperFingerprint.of(path: helperPath) else { return false }
        var answered = false
        for wait in waits {
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            guard let data = try? await channel.perform(operation: PrivilegedHelperService.pingOperation, arguments: [:]) else { continue }
            answered = true
            // The current helper, or an earlier one that has not stepped down yet (one from before HelperLifecycle never does; it is
            // replaced at the next restart): either way it is approved and answering, so it is left alone.
            if String(decoding: data, as: UTF8.self) == onDisk { return false }
        }
        guard needsRegistering(answered: answered) else { return false }
        do { try await unregister() } catch { return false }
        // Registering straight after unregistering can fail while launchd is still removing the job: retry briefly.
        for attempt in 0..<6 {
            do { try register(); return true } catch {
                if attempt == 5 { return false }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        return false
    }

    /// Registering again costs the user their approval, so it is done only when the approved helper never answered.
    public static func needsRegistering(answered: Bool) -> Bool { !answered }

    /// Why macOS reports the helper as "not found", worded for the Settings page. The usual cause is a quarantined app: macOS runs it
    /// from a randomized, read-only copy (App Translocation) and the helper cannot be registered from there.
    public static func notFoundReason(bundlePath: String, quarantined: Bool, containsLaunchDaemon: Bool) -> String {
        if !containsLaunchDaemon { return "This build of MacSpace does not contain the helper." }
        if bundlePath.contains("/AppTranslocation/") || quarantined {
            return "macOS is treating MacSpace as a downloaded app, so the helper cannot be installed. In Terminal run: xattr -dr com.apple.quarantine /Applications/MacSpace.app, then reopen MacSpace. (A notarized release does not need this.)"
        }
        if !isInApplicationsFolder(bundlePath) { return "Move MacSpace to the Applications folder, then reopen it." }
        return "Press Install helper. If macOS still does not recognise it, run in Terminal: /Applications/MacSpace.app/Contents/MacOS/MacSpaceCli helper --register and send the message it prints."
    }

    public static func notFoundReason(bundle: Bundle = .main) -> String {
        let path = bundle.bundlePath
        let quarantined = getxattr(path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0
        let plist = bundle.bundleURL.appendingPathComponent("Contents/Library/LaunchDaemons/\(PrivilegedHelperConstants.launchDaemonPlistName)").path
        return notFoundReason(bundlePath: path, quarantined: quarantined, containsLaunchDaemon: FileManager.default.fileExists(atPath: plist))
    }

    public static func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }
}
