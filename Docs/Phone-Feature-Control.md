# Phone feature control without a configuration profile

Issue 16 follow-up, 2026-10-18. The requested switch covers Phone recording/transcription, Live Voicemail/Call Screening,
FaceTime captions and call translation. A cleanup-only control does not meet this requirement. No configuration profile is to
be installed for this switch.

## Evidence on 26B5112a

Results and runnable, bounded research probes are in
`../MACSPACE/results/issue-16-phone-no-profile-20261018/`. This is a candidate implementation route with an explicit validation
boundary: native settings were tested with Apple's in-memory data-source initializer; effective feature-flag overrides have
**not** yet been applied/restarted on this machine. No current macOS feature setting was changed during these checks.

| Feature | Native control / upstream gate | Evidence |
| --- | --- | --- |
| Recording/transcription | `TUUserConfiguration.setCallRecordingEnabled:`; backing key `CallRecordingDisabled` | Real setter and inverse getter tested against an in-memory dictionary: on → off → on, with expected backing values. Installed `TUCallRecordingEnabled` checks the disabled preference after activatability. |
| Live Voicemail / Call Screening | `TUUserConfiguration.setCallScreeningEnabled:`; backing key `CallScreeningDisabled` | Same in-memory round trip. Installed `TUCallScreeningEnabled` is activatability AND not disabled. |
| FaceTime captions | `_AXSSetFaceTimeCaptionsEnabled`; `_AXSLiveTranscriptionInCallSetEnabled` | Exported native setters/getters exist. Complete setter disassembly writes the owning preference and uses Apple's notification path. Getters read off on this Mac. Setter effects on persistent settings/FaceTime UI remain to be checked. |
| Audio translation | `TelephonyUtilities/AudioCallTranslationMac` | Actual runtime getter instructions resolve to this domain/key. `CSDCall.translationDisabledError` checks the getter. |
| Video translation | `TelephonyUtilities/VideoCallTranslationMac` | Actual runtime getter resolves to this domain/key. With both audio/video getters false, `translationDisabledError` constructs translation error code 2. |

The five proposed upstream overrides are `CallRecording`, `CallScreeningEnabled`, `CaptionDeliveryForFaceTime`,
`AudioCallTranslationMac` and `VideoCallTranslationMac`, all in `TelephonyUtilities`. All five are declared on this build. Runtime
getter argument decoding confirmed these exact names; do not substitute the unsuffixed audio/video keys on macOS.

The existing Debloat mechanism supports root-owned overrides at
`/Library/Preferences/FeatureFlags/Domain/TelephonyUtilities.plist`. These are boot-time settings. Saving them is not proof that
the running feature is disabled. The implementation must use the existing pending-restart behavior and verify the effective
values after restarting. No daemon bootout, entitlement bypass, SIP change or profile is part of this route.

### Research ABI correction

`probe_call_screening_state.m` in the earlier Issue 16 research casts every function to `BOOL(void)`. That signature is unsafe for
`TUCallScreeningEnabled`: its installed implementation forwards three object arguments to `TUCallScreeningActivatable`, which
retains all three. The new read-only probe supplies three nil objects and succeeds. `TUCallRecordingEnabled` takes a feature-flags
object (nil selects the default). Native Objective-C getters/setters must also have their actual method encodings checked.
Never bring the older zero-argument C-function cast into the application.

`dyld_info -disassemble` rebuilds cache code with coordinates that differ from the runtime constant arguments. Resolving the
actual ADRP/ADD instructions of each leaf getter was necessary to distinguish the Mac translation keys. That decoder is a
research tool; application behavior should use a reviewed release-specific map and guarded native calls.

## Implementation requirements

- Feature management belongs to Siri & Apple Intelligence. Shared owner withdrawal and CacheDelete coordination belong to
  Platform, which System Data can use without importing Siri.
- Reuse the normal ToggleRow, badges and pending-restart state. Keep the page live during changes; follow module contract 5.
- Keep the existing Apple Intelligence language control independent. Turning Phone off must not modify Siri's Session Language.
- Journal native settings and full original override entries before changing anything. Preserve absence and restore original
  DevelopmentPhase metadata. Preserve unrelated entries and external changes in the same domain.
- Root operations accept a fixed feature scope and an on/off intent, never arbitrary paths, domains, keys or archives from UI
  parameters. Use the existing helper authentication boundary.
- Only report the combined switch off when every relevant native setting and effective flag verifies off. An unreadable value,
  partial failure, unreviewed release or pending restart cannot authorize model-owner withdrawal.
- After verified disablement, use the researched owner APIs in the logged-in user's session, scoped to that user's exact owners;
  then use the shared guarded CacheDelete path. Never edit the UAF database or delete AssetsV2 payloads directly.
- While the explicitly managed switch remains off, check for recreated demand and repeat the verified owner cleanup. Raw
  transcription-availability lists can still request assets after user features are disabled; list-expansion flags are not master
  feature switches. A recurring download does not by itself prove that the user's feature setting turned on.
- Preserve the Apple Intelligence safety gate. CacheDelete byte results are service-wide, not a Phone-specific freed-byte count.
- Explicit enablement/uninstall restores only MacSpace-owned state. Unknown/ambiguous owner operations require read-only
  reconciliation before another mutation.

## Validation still needed

The research folder contains a default-read-only `phone_flag_trial.py`. Explicit root `--apply` saves the original five entries
durably before changing them. Explicit `--restore` restores only those entries, preserves unrelated changes, and refuses external
drift. Both need a manual restart for their effective state. Fixture checks cover absent entries, DevelopmentPhase restoration,
unrelated changes, idempotent recovery and drift refusal. The trial does not change native user settings or clean any models.

The remaining live check is: apply these overrides deliberately, restart manually, run the read-only runtime probe, and have the
user verify the Phone/FaceTime controls. Then restore and verify again. Until that passes, the complete combined switch is not
validated for production UI.
