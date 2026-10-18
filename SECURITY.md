**English** · [Português](SECURITY.pt-BR.md) · [Español](SECURITY.es.md) · [Français](SECURITY.fr.md) · [Deutsch](SECURITY.de.md)

# Security Policy

MacSpace is a free, open-source (MIT) app for macOS. It runs with your normal user account. For
the few things that need an administrator, it uses a privileged helper that you approve once. It
collects no data about you. This document explains exactly what MacSpace touches on your Mac and
how to report a problem.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting:
[report a vulnerability](https://github.com/1architect/macspace-releases/security/advisories/new).
Or email **dev@giomantovani.com.br** with the details and steps to reproduce. Please do not open
a public issue for a security report. You get an acknowledgement within a few days.

What counts: anything that lets another program make the helper do what you did not ask, lets
MacSpace delete or change something it should not, or lets an update install without the release
signature.

## Supported versions

Security fixes go into the latest release only. Always update to the newest version from
[Releases](https://github.com/1architect/macspace-releases/releases/latest), with **Check for
Updates…**, or with `brew upgrade --cask macspace` (add `--greedy` if Homebrew skips it, because
MacSpace updates itself).

## What MacSpace does on your Mac

### Network

MacSpace makes network connections for one purpose: updates. When you choose **Check for
Updates…** (or **Check Now** in Settings), and, if you turned on **Check for updates
automatically**, about once a day while it runs, it reads the update feed hosted with the releases
on GitHub (`appcast.xml`). If you accept an update, it downloads the new version from GitHub
Releases. Nothing is sent about you, and Sparkle's optional system profile is not turned on.

There is no analytics, no telemetry, and no crash reporting. The details are in the
[Privacy Policy](PRIVACY.md).

### Where your data is stored

Everything stays on your Mac. MacSpace's files are in `~/Library/Application Support/MacSpace/`,
`~/Library/Logs/MacSpace/`, the preferences file `~/Library/Preferences/com.macspace.app.plist`,
and, for what the helper writes, `/Library/Application Support/MacSpace/`. The
[Privacy Policy](PRIVACY.md) lists each file. None of it is uploaded anywhere.

### What MacSpace deletes

| What | Where | Done by |
|---|---|---|
| Caches of apps that are closed | The per-user system cache folder (`/var/folders/…/C`), except Apple's own. The folders `Cache`, `Code Cache`, `GPUCache`, `DawnCache`, `DawnGraphiteCache`, `DawnWebGPUCache`, `GrShaderCache`, `ShaderCache` and `CachedData` inside a Chromium or Electron profile in `~/Library/Application Support`. | The app, as you |
| Diagnostic and crash reports older than 7 days | `/Library/Logs/DiagnosticReports` and `~/Library/Logs/DiagnosticReports`. A file you may not delete is skipped. | The app, as you |
| Unused system assets, released Apple Intelligence models, files apps marked purgeable | macOS's own purge service (CacheDelete). MacSpace asks for it in a short-lived child process, so a failure there cannot take the app down. | macOS |
| Local copies of cloud files | One cloud folder at a time (`~/Library/CloudStorage/…` or iCloud Drive). Only files that are uploaded and have no conflict. The files stay in the cloud. | The app, as you |
| Document version history | `/System/Volumes/Data/.DocumentRevisions-V100` | The helper |
| Leftover macOS update files | `/System/Volumes/Data/macOS Install Data`, only if older than the installed system. The `Locked Files` folder stays. | The helper |
| Unfinished wallpaper and screen saver downloads | `CFNetworkDownload_*.tmp` files directly in `/private/var/folders/*/*/T/com.apple.idleassetsd`, not changed for 3 days. Regular files only: links and subfolders are refused. | The helper |
| Copies macOS made of an app when it checked it | `/var/folders/…/X/<app>.code_sign_clone`, only when it holds space of its own (an older version's), while the app is closed and nothing runs from it. | The app, as you |
| The system log | `/private/var/db/diagnostics` and `/private/var/db/uuidtext`, with Apple's own `log erase --all` and `log erase --uuidtext`. | The helper |
| The symbols for crash reports | Everything in `/System/Library/Caches/com.apple.coresymbolicationd`, the folder stays; then `coresymbolicationd` is stopped so its space comes back. macOS rebuilds the cache. | The helper |
| The Trash | Everything in `~/.Trash`. An item that is locked or another account's stays. | The app, as you |
| Time Machine's local snapshots | `tmutil deletelocalsnapshots <date>`, one date at a time: all but the newest and the newest from a backup. Never while a backup runs. | The app, as you |
| Backups on a Time Machine backup disk | `tmutil delete`, the ones you choose, never the latest, on a connected disk Time Machine uses. Never while a backup runs. | The helper |

Nothing goes to the Trash. Caches, system assets and purgeable files are rebuilt or downloaded
again when needed, and cloud copies download again when you open the file. Reports, version history,
update leftovers, the system log, items in the Trash, snapshots and backups do not come back. Every one of these asks for confirmation first, except the
**Free** button of a single app's caches.

### What MacSpace changes (Debloat)

Each change is written to a journal first, so it can be undone with **Enable all** or by switching
the feature back on.

| Switch | What changes | Done by |
|---|---|---|
| Personalized ads | `com.apple.AdLib`, key `allowApplePersonalizedAdvertising` | The app, as you |
| Improve Siri & Dictation | `com.apple.assistant.support`, key `Siri Data Sharing Opt-In Status` | The app, as you |
| Crash report dialog | A launchd override for `com.apple.DiagnosticsReporter` and `com.apple.ReportGPURestart` | The app, as you |
| Share analytics with Apple (release builds of macOS) | `/Library/Application Support/CrashReporter/DiagnosticMessagesHistory.plist`, keys `AutoSubmit` and `ThirdPartyDataSubmit` | The helper |
| Siri AI, Visual Intelligence | Feature-flag overrides in `/Library/Preferences/FeatureFlags/Domain/` | The helper |
| Hang tracing (tailspin) | `tailspin disable`, and `tailspin enable` to undo it | The helper |
| The policies (six; seven on a beta of macOS) | One configuration profile, `com.macspace.policies` (see below) | You approve it in System Settings |

These changes stay in place if you delete the app without switching them back on.

### Apple Intelligence

The **Apple Intelligence** switch changes the key `Session Language` in
`com.apple.assistant.backedup`, which is Siri's language. Switched off, Siri gets a language other
than the system's, and your Siri voice (`Output Voice`) is left as it is. MacSpace saves both in
`~/Library/Application Support/MacSpace/ai-guard-saved-siri-settings.json` and restores them when
you switch Apple Intelligence on, or if the change does not take effect. If macOS keeps the models
after the switch is off, MacSpace may set the language to the system language and back, which takes
about a minute, to make macOS release them. With Siri's iCloud sync on, these changes also reach
your other devices on the same Apple Account. MacSpace cannot turn that sync off. It tells you
where to do it.

### Phone features

The Phone features switch in Siri & Apple Intelligence uses five fixed TelephonyUtilities overrides in
`/Library/Preferences/FeatureFlags/Domain/TelephonyUtilities.plist`: call recording, Call Screening, FaceTime caption delivery,
and the Mac audio/video translation gates. The authenticated helper saves original entries in
`/Library/Application Support/MacSpace/phone-features.json` before writing changes. Changes take effect after a restart; the
running gates are checked separately. Re-enabling restores those original entries, preserving unrelated overrides. The helper
refuses an entry changed outside MacSpace instead of overwriting it. This control installs no configuration profile and does not
change Siri's Session Language. Its helper operation accepts only an on/off intent, with no arbitrary path, domain or key.

### Feature models

The separate Siri and Spatial Photos switches save your original settings before disabling a feature. Siri's saved voice is
cleared while Siri is off; its Session Language is preserved. Phone also disables the local recording, screening and caption
settings. Originals are kept in `~/Library/Application Support/MacSpace/feature-settings/`.

Model requests are released through their owning Apple frameworks, in a separate MacSpace process that runs as you, never in
the app or the helper. That process checks each method against the one MacSpace reviewed before calling it and stops on any
difference. Rollback objects are saved, readable only by you, under `~/Library/Application Support/MacSpace/asset-owners/`. These feature and language-model cleanups never edit the live subscription database or delete model
payloads directly. Physical cleanup uses the existing guarded macOS cleanup service. It waits while Apple Intelligence is
available or its state is unreadable, keeps other accounts' requests, and keeps shared speech models while Dictation is active.

While MacSpace is open, explicitly disabled features are checked every five minutes and their unused models are cleaned again
if macOS requests them again. Re-enabling a feature or using MacSpace's uninstaller restores saved settings and model requests;
macOS may download the models again. An interrupted or conflicting owner operation is checked before any repeat request.
These controls are available only on verified macOS builds. Unused language assets in System Data use a one-shot cleanup;
that action does not disable spelling or dictionaries.

### Permissions

macOS handles each prompt, so MacSpace never sees your password.

| Permission | Where | What MacSpace uses it for |
|---|---|---|
| Full Disk Access | System Settings > Privacy & Security | Measuring folders macOS protects, and reading the Apple Intelligence state |
| Privileged helper | System Settings > General > Login Items & Extensions | The operations below |
| Configuration profile | System Settings > General > Device Management | Only when you switch off a Debloat policy |
| Notifications | macOS asks | Telling you that something finished |

### The privileged helper

The helper is a launch daemon, `com.macspace.helper`, registered with macOS from inside the app.
launchd starts it when MacSpace asks for something. It runs as root, and it accepts a connection only
from a program that satisfies this code-signing requirement, which macOS checks:

```
anchor apple generic and (identifier "com.macspace.app" or identifier "com.macspace.cli")
and certificate leaf[subject.OU] = "<the developer's team ID>"
```

It refuses to start without a requirement. It runs only named operations that are built into it.
A caller cannot send it commands. When the app is replaced by an update, the helper notices and
steps down so that the new one starts.

| Operation | What it does | Limits |
|---|---|---|
| `systemdata.measure` | Sizes of folders | Read-only. Only under `/private/var`, `/private/tmp`, `/Library`, `/System/Library`, the Data volume's root and `/opt`, never a home folder. Sizes, never contents. |
| `systemdata.versions.delete` | Deletes the document version history | Stops `revisiond` first, or pauses it if macOS refuses. Deletes the contents of the store, not the folder, then starts `revisiond` again. If it cannot stop it, it deletes nothing. |
| `systemdata.staged-update.delete` | Deletes leftover update files | Only if the folder is older than the installed system. Keeps `Locked Files`. |
| `systemdata.wallpaper-downloads.delete` | Deletes unfinished wallpaper and screen saver downloads | Takes no path: finds `/private/var/folders/*/*/T/com.apple.idleassetsd` itself, without following links. Deletes only regular files named `CFNetworkDownload_*.tmp` directly in it, not changed for 3 days. |
| `systemdata.unified-log.erase` | Erases the system log | Takes no argument. Runs only Apple's `/usr/bin/log erase --all`, then `log erase --uuidtext`. |
| `systemdata.symbolication-cache.delete` | Deletes the symbols for crash reports | Takes no argument. Only `/System/Library/Caches/com.apple.coresymbolicationd`, opened without following links; deletes what is in it, never the folder, then stops `coresymbolicationd` (`kill -TERM`, `-KILL` after 5 seconds). |
| `timemachine.backups.delete` | Deletes backups from a Time Machine backup disk | Only on a disk Time Machine lists as connected, only dates it finds there itself, never the latest backup, never while a backup runs or while that is unknown. Runs `/usr/bin/tmutil delete`. |
| `debloat.status`, `.apply`, `.revert` | Reads, switches off and switches on Debloat items | Control identifiers only, from the built-in catalog. Nothing else. |
| `debloat.removeProfile` | Removes a MacSpace profile | Only identifiers `com.macspace.policies` and `com.macspace.policies.…`. Any other profile is refused. |
| `siri.orphan-subscriptions.plan`, `.execute` | Finds and removes the Apple Intelligence subscriptions of accounts that no longer exist | Backs up the database to `/Library/Application Support/MacSpace/backups/` first, changes it in one transaction, touches only rows that match no local account, and refuses if the account list looks wrong. The app has no button for it yet. |
| `helper.ping` | Answers, so the app knows the helper is up | None |

The app's command-line tool, `MacSpaceCli`, inside the app bundle, can talk to the helper too. It
is signed with the same team.

### The configuration profile

Debloat's policies are settings only a configuration profile can force. MacSpace builds one
profile, `com.macspace.policies` (shown as **MacSpace: policies**, organization "MacSpace"), with
every policy you switched off. It opens the profile, and you approve it in System Settings >
General > Device Management. Approving it replaces the earlier one. It is not marked as
impossible to remove. Switching the last policy back on removes it, through the helper, with
nothing to approve. You can also remove it yourself in System Settings.

### Code signing and updates

MacSpace is signed with an Apple Developer ID, with the hardened runtime, and notarized by Apple.
The notarization ticket is stapled to the app, so it also opens offline. Sparkle's own components
are signed with the same identity.

Updates are signed with an EdDSA key as well. Its public half is inside MacSpace (`SUPublicEDKey`),
and Sparkle checks every download against it before installing. The private half of that key and
the signing identity are not in this repository. A copy of MacSpace built without the public key
never checks for updates.

## Verify a download

Put `MacSpace-x.y.z.dmg` and `MacSpace-x.y.z.dmg.sha256` in one folder:

```bash
shasum -a 256 -c MacSpace-x.y.z.dmg.sha256
```

Then, after you drag MacSpace to Applications:

```bash
codesign -dv --verbose=4 /Applications/MacSpace.app
codesign --verify --deep --strict --verbose=2 /Applications/MacSpace.app
spctl -a -vv /Applications/MacSpace.app
xcrun stapler validate /Applications/MacSpace.app
```

You should see `Authority=Developer ID Application`, `TeamIdentifier=J45ZXS2ZF6`, the `runtime`
flag, `Notarization Ticket=stapled`, and `spctl` should say `accepted` with
`source=Notarized Developer ID`.

## Uninstall completely

There is no in-app uninstaller. The full steps are in the
[README](README.md#uninstall). In short:

1. In **Debloat**, press **Enable all**. This removes the overrides and the profile it made.
2. If the profile **MacSpace: policies** is still in System Settings > General > Device
   Management, remove it.
3. Quit MacSpace. Turn it off under System Settings > General > Login Items & Extensions, or run
   `/Applications/MacSpace.app/Contents/MacOS/MacSpaceCli helper --unregister`.
4. Remove the app: `brew uninstall --cask macspace`, or drag **MacSpace** to the Trash.
5. Remove its data and preferences:
   ```bash
   rm -rf ~/Library/Application\ Support/MacSpace ~/Library/Logs/MacSpace ~/Library/Caches/com.macspace.app
   defaults delete com.macspace.app
   sudo rm -rf /Library/Application\ Support/MacSpace
   ```
6. Remove MacSpace from System Settings > Privacy & Security > Full Disk Access.
