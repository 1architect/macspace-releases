import CoreServices
import Foundation

/// Asks macOS to show its own Restart dialog, the one Apple menu > Restart… opens: the user confirms or cancels there, and apps are
/// asked to save as they are then. MacSpace never restarts the Mac by itself. For a change that only a restart completes (a setting
/// read at startup, models that services macOS keeps running still hold open).
public enum SystemRestart {
    /// `kAEShowRestartDialog` ('rrst'), sent to loginwindow. False when the dialog could not be asked for.
    @discardableResult
    public static func showDialog() -> Bool {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.loginwindow")
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(0x72727374) /* rrst */,
                                           targetDescriptor: target, returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        guard let descriptor = event.aeDesc else { return false }
        return AESendMessage(descriptor, nil, AESendMode(kAENoReply), kAEDefaultTimeout) == noErr
    }
}
