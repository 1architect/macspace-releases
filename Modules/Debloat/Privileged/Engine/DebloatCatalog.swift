import Foundation

/// The built-in control catalog.
///
/// Rules for entries:
/// - `validatedBuilds` lists only builds where a before/after experiment showed the effect; one build is enough for every build.
///   An empty list means the control was never tested: the app marks it "Not tested" so it gets tested.
/// - Preference keys that come from community documentation rather than measurement say so in `notes`.
/// - `breaks` names every feature known to depend on what the control switches off.
public enum DebloatCatalog {
    static let diagnosticsFile = "/Library/Application Support/CrashReporter/DiagnosticMessagesHistory"
    static let policyNote = "Restriction key from ManagedConfiguration's defaultSettings.plist on 26B5091g, not marked supervised-only. Measured on 26B5091g without MDM: macOS forces it once the MacSpace policies profile is approved; the behavioral effect is unmeasured."
    static let flagNote = "Feature-flag overrides are read at boot: the change applies after a reboot. Survival across OS updates is unmeasured."
    static let bootClearedNote = "With SIP enabled on 26B5091g, launchd cleared this override at boot and again at login (\"Clearing enabled state\") and refused bootout (error 150); owner-enforced overrides such as Siri.agent survive."

    public static let controls: [DebloatControl] = [
        DebloatControl(
            id: "telemetry.diagnostics-policy",
            title: "Share analytics with Apple",
            summary: "Force diagnostics submission off with a configuration profile (SubmitDiagInfo AutoSubmit and the allowDiagnosticSubmission restriction).",
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
            validatedBuilds: ["26B5091g"]
        ),
        DebloatControl(
            id: "ads.personalized-ads-policy",
            title: "Personalized ads",
            summary: "Force personalized ads off with a configuration profile (allowApplePersonalizedAdvertising restriction).",
            category: .advertising, mechanism: .configurationProfile, risk: .low, restart: .appRelaunch,
            settings: [.managed("com.apple.applicationaccess", "allowApplePersonalizedAdvertising", desired: .bool(false))],
            breaks: ["The personalized-ads switch becomes locked off in System Settings"],
            notes: ["Measured on 26B5091g without MDM: the profile forced the restriction and a derived com.apple.AdLib value."]
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
        DebloatControl(
            id: "ads.advertising-identifier-policy",
            title: "Advertising identifier",
            summary: "Force the advertising identifier off with the allowIdentifierForAdvertising restriction.",
            category: .advertising, mechanism: .configurationProfile, risk: .low, restart: .appRelaunch,
            settings: [.managed("com.apple.applicationaccess", "allowIdentifierForAdvertising", desired: .bool(false))],
            notes: [policyNote]
        ),
        DebloatControl(
            id: "telemetry.siri-server-logging-policy",
            title: "Siri server-side logging",
            summary: "Disallow Siri server-side logging (allowSiriServerLogging restriction).",
            category: .telemetry, mechanism: .configurationProfile, risk: .low, restart: .none,
            settings: [.managed("com.apple.applicationaccess", "allowSiriServerLogging", desired: .bool(false))],
            notes: [policyNote]
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
            notes: [policyNote]
        ),
        DebloatControl(
            id: "suggestions.spotlight-internet-policy",
            title: "Spotlight internet results",
            summary: "Stop Spotlight from sending queries to Apple for internet results and suggestions (allowSpotlightInternetResults).",
            category: .suggestions, mechanism: .configurationProfile, risk: .low, restart: .appRelaunch,
            settings: [.managed("com.apple.applicationaccess", "allowSpotlightInternetResults", desired: .bool(false))],
            breaks: ["Siri Suggestions and web results in Spotlight"],
            notes: [policyNote]
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
            ]
        ),
        DebloatControl(
            id: "apps.game-center-policy",
            title: "Game Center",
            summary: "Disable Game Center with the allowGameCenter restriction.",
            category: .appServices, mechanism: .configurationProfile, risk: .medium, restart: .logout,
            settings: [.managed("com.apple.applicationaccess", "allowGameCenter", desired: .bool(false))],
            breaks: ["Game Center sign-in, achievements, leaderboards and multiplayer"],
            notes: [policyNote, "Measured on 26B5091g: gamed still launches on demand and contacts Apple with the restriction in place; it is not a daemon switch."]
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
            notes: [policyNote, "Measured on 26B5091g: LaunchServices hides News (`open -a News` fails), but opening News.app by path still works."]
        ),
    ]

    public static func control(_ id: String) -> DebloatControl? { controls.first { $0.id == id } }
}
