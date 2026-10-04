import Foundation

/// Siri's iCloud sync: the "Siri" switch under System Settings > Apple Account > iCloud > Saved to iCloud ("Sync this Mac").
///
/// MacSpace cannot change it, nor read it. The switch is a data class of the iCloud account (`ACAccountDataclassSiri`), kept by
/// accountsd, which shows the account only to processes Apple entitles (an app sees no account at all; tested 2026-10-04). The
/// `Cloud Sync Enabled` key in `com.apple.assistant.backedup` is Siri's own preference, not that switch: writing it left
/// System Settings unchanged. So MacSpace says what the switch does and opens the page that has it.
///
/// It matters because MacSpace switches Apple Intelligence off by changing the Siri language, and with sync on the iPhone and
/// iPad follow (measured 2026-10-04).
public enum SiriCloudSync {
    /// The Apple Account page of System Settings, at iCloud.
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings:icloud")!

    public static let steps = [
        "Open System Settings > Apple Account > iCloud.",
        "Under Saved to iCloud, click See All, then Siri.",
        "Turn off Sync this Mac, and choose to keep Siri's data on this Mac.",
    ]

    /// Where a Siri language change goes.
    public static let reach = "With Siri's iCloud sync on, iPhone and iPad signed in to the same Apple Account get the same Siri language. Turn it off in iCloud settings to keep the change on this Mac."
}
