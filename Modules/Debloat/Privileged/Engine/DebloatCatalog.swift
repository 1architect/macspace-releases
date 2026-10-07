import Foundation
import MacSpacePlatform

/// The built-in control catalog.
///
/// Rules for entries:
/// - `validatedBuilds` lists only builds where a before/after experiment showed the effect; one build is enough for every build.
///   An empty list means the control was never tested: the app marks it "Not tested" so it gets tested.
/// - Preference keys that come from community documentation rather than measurement say so in `notes`.
/// - `breaks` names every feature known to depend on what the control switches off.
public enum DebloatCatalog {
    static let diagnosticsFile = "/Library/Application Support/CrashReporter/DiagnosticMessagesHistory"
    /// Research (results/debloat-validation/profile-policies-2026-09-29 in the private repository): on 26B5091g with SIP enabled and
    /// no MDM, every policy key was applied through an approved profile and read back forced; the controls read debloated.
    static let policyNote = "Restriction key from ManagedConfiguration's defaultSettings.plist, not marked supervised-only. Tested on 26B5091g (2026-09-29) without MDM: macOS forces it once its profile is approved."
    /// AssistantServices' preference-change notification, as it names it on the running build.
    static let assistantPreferencesChanged = DarwinNotificationName.exported(
        framework: "/System/Library/PrivateFrameworks/AssistantServices.framework/AssistantServices",
        symbol: "kAFPreferencesDidChangeDarwinNotification")
    static let flagNote = "Feature-flag overrides are read at boot: the change applies after a reboot. Survival across OS updates is unmeasured."
    static let bootClearedNote = "With SIP enabled on 26B5091g, launchd cleared this override at boot and again at login (\"Clearing enabled state\") and refused bootout (error 150); owner-enforced overrides such as Siri.agent survive."

    public static let controls: [DebloatControl] = [
        // On a release build the System Settings switch is honored, so it is what MacSpace changes: no profile to approve.
        DebloatControl(
            id: "telemetry.diagnostics",
            title: "Share analytics with Apple",
            summary: "Turn off Share Mac Analytics and sharing with app developers, as System Settings > Privacy & Security > Analytics & Improvements does.",
            category: .telemetry, mechanism: .systemPreference, risk: .low, restart: .none,
            settings: [
                .preference(.systemFile, diagnosticsFile, "AutoSubmit", desired: .bool(false), fallback: nil),
                .preference(.systemFile, diagnosticsFile, "ThirdPartyDataSubmit", desired: .bool(false), fallback: nil),
            ],
            effect: .diagnosticSubmission,
            notes: ["On release builds only. On a beta, macOS submits diagnostics whatever this says, and the profile control replaces it."],
            audience: .release
        ),
        // On a beta (SeedAutoSubmit), macOS submits whatever System Settings says; only a profile stops it.
        DebloatControl(
            id: "telemetry.diagnostics-policy",
            title: "Share analytics with Apple",
            summary: "Force diagnostics submission off with a configuration profile (SubmitDiagInfo AutoSubmit and the allowDiagnosticSubmission restriction). On a beta build macOS submits diagnostics whatever System Settings says; this is what stops it.",
            category: .telemetry, mechanism: .configurationProfile, risk: .low, restart: .none,
            settings: [
                .managed("com.apple.SubmitDiagInfo", "AutoSubmit", desired: .bool(false)),
                .managed("com.apple.applicationaccess", "allowDiagnosticSubmission", desired: .bool(false)),
            ],
            effect: .diagnosticSubmission,
            breaks: ["Share Mac Analytics and diagnostics sharing become locked off in System Settings"],
            notes: [
                "Measured on 26B5091g without MDM: a user-approved profile forced both values and they survived a reboot.",
                "Measured on 26B5091g (seed, SeedAutoSubmit=1): with the profile SubmitDiagInfo decided optIn: OUT and uploaded nothing; without it, optIn: IN and an upload.",
            ],
            validatedBuilds: ["26B5091g"],
            audience: .prerelease
        ),
        // The switches in System Settings > Privacy & Security > Apple Advertising, plain user settings (com.apple.AdLib in the
        // 2026-09-25 baseline): no profile to approve.
        DebloatControl(
            id: "ads.personalized-ads",
            title: "Personalized ads",
            summary: "Turn off personalized ads from Apple, as the Personalized Ads switch in System Settings > Privacy & Security > Apple Advertising does.",
            category: .advertising, mechanism: .userPreference, risk: .low, restart: .appRelaunch,
            settings: [.preference(.user, "com.apple.AdLib", "allowApplePersonalizedAdvertising", desired: .bool(false), fallback: .value(.bool(true)))],
            notes: ["Self-tested on 26B5091g (2026-10-03): off stores 0, on stores 1."],
            validatedBuilds: ["26B5091g"]
        ),
        // A policy, not the plain com.apple.AdLib value: macOS has no switch of its own for it ("Cross App Tracking is not currently
        // persisted on this platform", LimitAdTracking), and reconciles the plain value with the Apple Account, back to allowed: on
        // 26B5091g it came back on within a day, three times (2026-10-04 to 10-06), while Personalized ads stayed off.
        DebloatControl(
            id: "ads.advertising-identifier-policy",
            title: "Advertising identifier",
            summary: "Stop apps from using the advertising identifier, and from asking to track you, with the allowIdentifierForAdvertising restriction.",
            category: .advertising, mechanism: .configurationProfile, risk: .low, restart: .appRelaunch,
            settings: [.managed("com.apple.applicationaccess", "allowIdentifierForAdvertising", desired: .bool(false))],
            notes: [policyNote],
            validatedBuilds: ["26B5091g"]
        ),
        DebloatControl(
            id: "siri.siri-ai-flag",
            title: "Siri AI",
            summary: "Turn off the IntelligenceFlow/Campo feature flag so launchd never loads Siri AI.app; classic Spotlight takes its place.",
            category: .siri, mechanism: .featureFlag, risk: .medium, restart: .reboot,
            settings: [.flag("IntelligenceFlow", "Campo")],
            effect: .processesAbsent(["/System/Applications/Siri AI.app/Contents/MacOS/Siri AI"]),
            breaks: ["Siri AI", "The Siri AI search experience (classic Spotlight.app is used instead)"],
            notes: [
                "Measured on 26B5091g with SIP enabled: after the reboot the flag read disabled, com.apple.campo was not loaded and Siri AI did not run.",
                "com.apple.Spotlight is disabled while Campo is enabled, so the override brings classic Spotlight back.",
                flagNote,
            ],
            validatedBuilds: ["26B5091g"]
        ),
        DebloatControl(
            id: "ai.visual-intelligence",
            title: "Visual Intelligence",
            summary: "Turn off the Tamale/DaemonEnabled feature flag so launchd never loads visualintelligenced.",
            category: .appleIntelligence, mechanism: .featureFlag, risk: .medium, restart: .reboot,
            settings: [.flag("Tamale", "DaemonEnabled")],
            effect: .processesAbsent(["/System/Library/PrivateFrameworks/VisualIntelligenceServices.framework/visualintelligenced"]),
            breaks: ["Visual Intelligence", "Possibly Visual Look Up and other features that call the service (unmeasured)"],
            notes: [
                "visualintelligenced's launchd plist is Disabled when this flag is off (26B5091g).",
                "Measured on 26B5091g with SIP enabled: after the reboot the flag read disabled and visualintelligenced was not loaded.",
                flagNote,
            ],
            validatedBuilds: ["26B5091g"]
        ),
        DebloatControl(
            id: "ai.generative-indexing",
            title: "Generative search indexing",
            summary: "Turn off the GenerativeLearningPlatform platform-daemon, observation-indexing and Mail-indexing flags so launchd never loads hybridsearchd.",
            category: .appleIntelligence, mechanism: .featureFlag, risk: .high, restart: .reboot,
            settings: [
                .flag("GenerativeLearningPlatform", "PlatformDaemons"),
                .flag("GenerativeLearningPlatform", "ObservationIndexing"),
                .flag("GenerativeLearningPlatform", "MailIndexing"),
            ],
            effect: .processesAbsent(["/usr/libexec/hybridsearchd"]),
            breaks: ["Apple Intelligence search over Mail and personal context", "Other features behind these broad flags (unmeasured)"],
            notes: [
                "hybridsearchd is Disabled only when all three flags are off (26B5091g).",
                "26B5101f no longer declares PlatformDaemons in the GenerativeLearningPlatform domain; it reads disabled, and hybridsearchd's launchd plist still tests it, so the other two flags decide (read 2026-10-07, not measured with a reboot).",
                "Measured on 26B5091g with SIP enabled: after the reboot all three flags read disabled and hybridsearchd was not loaded; intelligenceplatformd and intelligencetasksd still launched on demand.",
                flagNote,
            ],
            validatedBuilds: ["26B5091g"]
        ),
        DebloatControl(
            id: "diagnostics.tailspin",
            title: "Hang tracing (tailspin)",
            summary: "Stop tailspin, which keeps a 100 MB kernel trace buffer and samples every process every 10 ms so hang reports can look back ~20 s.",
            category: .diagnostics, mechanism: .systemTool, risk: .low, restart: .none,
            settings: [.tool(.tailspin)],
            breaks: [
                "The last ~20 s of system history in spindump hang reports, sysdiagnose and Feedback Assistant attachments",
                "The Shift-Control-Option-Command-Comma tailspin capture",
            ],
            notes: [
                "Apple-supported: tailspin(1) says disable persists across reboots and upgrade installs; `tailspin enable` restores it.",
                "Observed on 26B5091g: enabled by default with a 100 MB buffer and 10 ms full-system sampling.",
                "Measured on 26B5091g with SIP enabled: disable released ~100 MB of wired memory and persisted across a reboot.",
            ],
            validatedBuilds: ["26B5091g"]
        ),
        DebloatControl(
            id: "diagnostics.crash-reporter",
            title: "Crash report dialog",
            summary: "Disable Diagnostics Reporter (the \"quit unexpectedly\" dialog) and GPU-restart reporting.",
            category: .diagnostics, mechanism: .launchdOverride, risk: .low, restart: .reboot,
            settings: [
                .service(.gui, "com.apple.DiagnosticsReporter"),
                .service(.gui, "com.apple.ReportGPURestart"),
            ],
            effect: .processesAbsent([
                "/System/Library/CoreServices/Diagnostics Reporter.app/Contents/MacOS/Diagnostics Reporter",
                "/System/Library/Frameworks/OpenGL.framework/Versions/A/Libraries/ReportGPURestart",
            ]),
            breaks: ["The \"quit unexpectedly\" dialog and its Report button", "GPU restart reports"],
            notes: [
                "Both labels are in RemovableServices; measured on 26B5091g with SIP enabled, the overrides survived a reboot and neither job was loaded.",
                "Crash reports themselves continue: launchd force-enables com.apple.ReportCrash and com.apple.ReportCrash.Root and ignores their overrides (measured on 26B5091g), so they are not part of this control.",
            ],
            validatedBuilds: ["26B5091g"]
        ),
        // "Improve Siri & Dictation" in System Settings > Privacy & Security > Analytics & Improvements: 2 is opted out, as in the
        // 2026-09-25 baseline. A plain user setting, so no profile. AssistantServices owns the domain; after a write it posts the
        // notification it exports, kAFPreferencesDidChangeDarwinNotification (research results/cp107), so Siri's processes read it again.
        DebloatControl(
            id: "telemetry.siri-improvement",
            title: "Improve Siri & Dictation",
            summary: "Stop sharing Siri and Dictation audio and transcripts with Apple, as the Improve Siri & Dictation switch does.",
            category: .telemetry, mechanism: .userPreference, risk: .low, restart: .none,
            settings: [.preference(.user, "com.apple.assistant.support", "Siri Data Sharing Opt-In Status", desired: .int(2), fallback: .value(.int(1)),
                                   notification: assistantPreferencesChanged)],
            notes: ["Self-tested on 26B5091g (2026-10-03): off stores 2, on stores 1."],
            validatedBuilds: ["26B5091g"]
        ),
        DebloatControl(
            id: "telemetry.on-device-speech-policy",
            title: "Dictation and translation on Apple servers",
            summary: "Force dictation and translation to run on device only, so audio and text are not sent to Apple's servers.",
            category: .telemetry, mechanism: .configurationProfile, risk: .low, restart: .appRelaunch,
            settings: [
                .managed("com.apple.applicationaccess", "forceOnDeviceOnlyDictation", desired: .bool(true)),
                .managed("com.apple.applicationaccess", "forceOnDeviceOnlyTranslation", desired: .bool(true)),
            ],
            breaks: ["Dictation and translation in languages without an on-device model"],
            notes: [policyNote],
            validatedBuilds: ["26B5091g"]
        ),
        DebloatControl(
            id: "suggestions.spotlight-internet-policy",
            title: "Spotlight internet results",
            summary: "Stop Spotlight from sending queries to Apple for internet results and suggestions (allowSpotlightInternetResults).",
            category: .suggestions, mechanism: .configurationProfile, risk: .low, restart: .appRelaunch,
            settings: [.managed("com.apple.applicationaccess", "allowSpotlightInternetResults", desired: .bool(false))],
            breaks: ["Siri Suggestions and web results in Spotlight"],
            notes: [policyNote],
            validatedBuilds: ["26B5091g"]
        ),
        DebloatControl(
            id: "ai.features-policy",
            title: "Apple Intelligence features",
            summary: "Disable Writing Tools, Genmoji, Image Playground, Image Wand, summaries, smart replies, ChatGPT integration and Apple Intelligence reports.",
            category: .appleIntelligence, mechanism: .configurationProfile, risk: .medium, restart: .appRelaunch,
            settings: [
                .managed("com.apple.applicationaccess", "allowWritingTools", desired: .bool(false)),
                .managed("com.apple.applicationaccess", "allowGenmoji", desired: .bool(false)),
                .managed("com.apple.applicationaccess", "allowImagePlayground", desired: .bool(false)),
                .managed("com.apple.applicationaccess", "allowImageWand", desired: .bool(false)),
                .managed("com.apple.applicationaccess", "allowPhotorealisticImageGeneration", desired: .bool(false)),
                .managed("com.apple.applicationaccess", "allowMailSummary", desired: .bool(false)),
                .managed("com.apple.applicationaccess", "allowMailSmartReplies", desired: .bool(false)),
                .managed("com.apple.applicationaccess", "allowNotesTranscriptionSummary", desired: .bool(false)),
                .managed("com.apple.applicationaccess", "allowSafariSummary", desired: .bool(false)),
                .managed("com.apple.applicationaccess", "allowVisualIntelligenceSummary", desired: .bool(false)),
                .managed("com.apple.applicationaccess", "allowExternalIntelligenceIntegrations", desired: .bool(false)),
                .managed("com.apple.applicationaccess", "allowAppleIntelligenceReport", desired: .bool(false)),
            ],
            breaks: ["The listed Apple Intelligence features"],
            notes: [
                policyNote,
                "Does not evict the on-device model: CP110 showed Screen Time/MDM restrictions leave ModelCatalog's selection unchanged; use ai.apple-intelligence for that.",
            ],
            validatedBuilds: ["26B5091g"]
        ),
        DebloatControl(
            id: "apps.game-center-policy",
            title: "Game Center",
            summary: "Disable Game Center with the allowGameCenter restriction.",
            category: .appServices, mechanism: .configurationProfile, risk: .medium, restart: .logout,
            settings: [.managed("com.apple.applicationaccess", "allowGameCenter", desired: .bool(false))],
            breaks: ["Game Center sign-in, achievements, leaderboards and multiplayer"],
            notes: [policyNote, "Measured on 26B5091g: gamed still launches on demand and contacts Apple with the restriction in place; it is not a daemon switch."],
            validatedBuilds: ["26B5091g"]
        ),
        DebloatControl(
            id: "apps.news-policy",
            title: "Apple News",
            summary: "Disable Apple News and its widgets with the allowNews and allowNewsToday restrictions.",
            category: .appServices, mechanism: .configurationProfile, risk: .low, restart: .logout,
            settings: [
                .managed("com.apple.applicationaccess", "allowNews", desired: .bool(false)),
                .managed("com.apple.applicationaccess", "allowNewsToday", desired: .bool(false)),
            ],
            breaks: ["Apple News app", "News widgets"],
            notes: [policyNote, "Measured on 26B5091g: LaunchServices hides News (`open -a News` fails), but opening News.app by path still works."],
            validatedBuilds: ["26B5091g"]
        ),
    ]

    public static func control(_ id: String) -> DebloatControl? { controls.first { $0.id == id } }
}
