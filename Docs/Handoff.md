# Handoff

Everything someone needs to pick this project up: what exists, how to build and test it, how it is put together, what is verified,
and what is still open. Findings about macOS itself are in [Research.md](Research.md); the research that came before the app is summarized in [Original-Research.md](Original-Research.md).

## What MacSpace is

A modular macOS 27 utility. One app shows widgets that **modules** describe; each module is a separate plug-in. Three ship today:

| Module | What it does |
|---|---|
| **System Data** | Explains what fills System Data, frees what is safe (system caches, old reports, unused system assets), deletes the document version history on request, and guides the manual cleanup macOS and other apps own. |
| **Siri & Apple Intelligence** | An off-switch for Apple Intelligence, a background watcher, and release of the models macOS keeps afterwards. Does nothing in a virtual machine. |
| **Other System Files** | What macOS counts as purgeable, per purge service, and freeing the files apps marked purgeable now instead of when the disk is nearly full. |
| **Debloat** | Fourteen switches for analytics, ads and background data collection macOS lets you control, and a background watch that switches off again what macOS turns back on, with a notification. |

Third-party plug-ins are out of scope. The app is built with SwiftPM only (no Xcode project) and requires macOS 27.

## Repository layout

Folders start with a capital letter. Everything here is public; signing material and the release pipeline are not (see
[Releasing](#releasing)).

| Folder | Contents |
|---|---|
| `App/` | The app: module registry and scanner, the SwiftUI renderer, Home, Settings, menu bar, updates (Sparkle). |
| `Sdk/` | A separate package: the contract between app and modules (`MacSpaceModule`, `Screen` and widgets, options, permissions). |
| `Platform/` | A separate package: command runner, file sizing, permissions, CacheDelete client, the helper (XPC, installer, service). |
| `Modules/<Name>/Module` | The module's code. `Bundle/` holds its `Info.plist` and `Manifest.json`; `Privileged/` holds operations compiled into the helper. |
| `Helper/` | The privileged helper executable. |
| `Cli/` | `MacSpaceCli`, a command-line tool shipped inside the app (diagnostics, screens as JSON, the isolated purge process). |
| `Scripts/` | `Assemble.sh` builds the `.app`; `MakeIcon.swift` makes the icon. |
| `Packaging/` | The helper's launchd plist template. |
| `Tests/` | One test target per area. |
| `Docs/` | This folder. |

`Sdk` and `Platform` are separate packages on purpose: SwiftPM links a target's dependencies into every dynamic library that uses it,
which gave each module its own copy of the SDK types and broke type casts across the app/module boundary.

## Build, run, test

Use the Xcode 27 toolchain; the command-line tools alone lack the SwiftUI macros.

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
```

```bash
swift test
```

```bash
INSTALL=1 Scripts/Assemble.sh
```

`Assemble.sh` builds `Build/MacSpace.app` (app, shared libraries, Sparkle, one `.macspacemodule` bundle per module, the helper and
its launchd plist, the CLI) and signs it inside-out. `INSTALL=1` also quits any running copy and copies the app to
`/Applications` (asking for an administrator password if that folder is not writable; `INSTALL_DIR` chooses another), removing a copy
earlier builds left in `~/Applications`. **Run the app from an Applications folder**: the helper only registers from there.

Settings of the script, as environment variables: `CONFIG` (default `release`), `VERSION`, `BUILD`, `SIGN_IDENTITY` (default: the
first Developer ID or Apple Development identity in the keychain, otherwise ad-hoc; `-` forces ad-hoc), `TEAM_ID`,
`SPARKLE_PUBLIC_KEY` (without it the build never checks for updates). Other variables: `MACSPACE_MODULES_DIR` points the app or CLI
at another folder of modules; `MACSPACE_CLI` overrides where the CLI is found.

Useful CLI commands (from `Build/MacSpace.app/Contents/MacOS/MacSpaceCli`):

| Command | Use |
|---|---|
| `modules [--dir <folder>] [--load]` | Lists the modules the app would load; `--load` runs each one. |
| `screen <module-id> [--dir <folder>]` | Prints a module's real screen as JSON. |
| `helper [--register] [--ping]` | Helper status, the reason when it is "not found", registering, and a ping. |
| `purge-assets [--execute] [--all-services] [--service <id>] [--urgency 1-4]` | CacheDelete query and purge (see Research). |
| `orphan-subscriptions [--execute]` | Removes subscription rows of deleted accounts (needs root). |

## How it fits together

1. **Discovery.** At launch the app scans `Contents/PlugIns` for `*.macspacemodule` bundles and reads each `Manifest.json` (id, name,
   SDK version, minimum macOS, permissions, options, background tasks) **without running any code**. Compatible, enabled modules are
   then loaded through their principal class (`MacSpaceModuleEntry`). All modules load side by side.
2. **Declarative UI.** A module returns a `Screen` of widgets (banner, usage bar, chart, list, toggles, button, steps, text,
   section) and a summary widget for the Home tile. The app draws them. Actions come back as `ActionRequest`s; the app checks the
   action's `requires` permissions and shows its confirmation first. A row's subtitle is a short grey note after its title; its
   detail and steps, a section's subtitle and a list's footnote open from a small (i) in a Liquid Glass popover (`InfoButton`).
   Give an item a description only when the title is not enough (something the user can do, or a risk), in one or two short
   sentences: no (i) is drawn without one. Rows are drawn without symbols, and modules are named without theirs.
3. **Switches show the feature.** On every toggle, on means the feature runs and off means MacSpace switched it off. Debloat follows
   this too; keep it for new modules.
4. **Caching.** Each module keeps one shared scan (`…Store`) so the Home tile and the page do not scan twice. The Refresh button
   calls the module's `invalidate()` first.
5. **Privileged work** goes through the helper. A module's `Privileged/` library declares named operations (`siri.orphan-subscriptions.*`,
   `debloat.*`, `systemdata.measure`, `systemdata.versions.delete`); `Helper/MacSpaceHelper.swift` registers them. The helper accepts
   only clients that satisfy a code-signing requirement passed on its command line and refuses to start without one.
6. **Crash isolation.** Private Apple calls (CacheDelete) run in the CLI as a child process.
7. **Settings.** General (theme, appearance, a row opening the Permissions page, what closing the window does, login, updates), Cleanup
   (automatic cleanup and the history), Notifications, the module switches, then options and background tasks per module. Sections are built directly in
   `SettingsView`; wrapping them in custom views inside a `ForEach` made them render inside the wrong card.
8. **Look.** A theme is a night and day pair of palettes (`PaletteScheme.themes`); Settings chooses the theme and whether it follows the
   system, or stays night or day. Whatever needs the user is drawn in the action color (amber, lime on Ink); the app has no red.
9. **Menu bar.** An `NSStatusItem` (`StatusItemController`): a click opens the app, a right click opens its menu (each module with
   its tile's status, opening its page). `AppRouter` opens the window from outside it; when no window has been open since launch it
   opens `macspace://<window id>`, which the window scenes claim. Closing the window quits MacSpace, keeps it in the menu bar, or
   keeps it running in the background (`GeneralSettings.ClosedWindow`): with no menu bar item, and out of the Dock and the app
   switcher (an accessory app) until a window opens again (`BackgroundPresence`); opening MacSpace again shows the window.
   The old "Show in the menu bar" switch is read as menu bar (on) or quit (off) until a choice is made.
   **Notifications** (`AppNotifications`): automatic cleanup that freed at least 100 MB, an action of 8 s or more that ends while
   MacSpace is not in front, and the disk under 10 GB or 5% free (once a day at most). Each one can be switched off in Settings; a
   click opens the page it is about (the modules' own notifications carry `"module": <id>` for that).
10. **Window menu.** SwiftUI lists every window scene there, open or not ("MacSpace" twice and the Shader Studio). The standard
    window and the Shader Studio scenes carry `.commandsRemoved()`, and with them the menu lists none (checked with System Events).
    Not on the first scene: on all three it also removed Quit and the Edit, Window and Help menus. `CommandGroup(replacing:
    .windowList)` removes Bring All to Front, not the scenes' items.
11. **Disk tile.** One `StorageOverview.shared`, read again when a cleanup ends (and 5 and 20 s later), when a module's figures
    change, when the app comes back to the front, and every 30 s while a window shows it.
12. **System Data's total** is System Settings' own remainder, computed the way its Storage pane computes it (`SettingsStorage` in
    Platform: used, less macOS and every other category, each a fixed set of places read from Settings' code; Research, "How System
    Settings computes its categories"). Nothing has to list what System Data holds, so whatever a Mac has that MacSpace does not know
    still lands in it. The page's items are only the breakdown: what they leave out of the total is a "Not identified" block, so a
    rule that goes wrong shows as a measured amount instead of a wrong total. The same places decide which items are System Data
    (`SystemDataItem.elsewhereBytes`). The debug command `settings:<file.json>` writes the reading.
13. **Design tools.** The Design menu and the Shader Studio exist only with `--design-tools` (`open -a MacSpace --args --design-tools`)
    or `MACSPACE_DESIGN=1`. `MACSPACE_DEBUG=1` turns on `DebugRemote` (window capture, navigation, and `du:` which sizes folders with
    the app's own Full Disk Access).

### Adding a module

1. Create `Modules/<Name>/{Module,Bundle}` (add `Privileged/` if it needs root).
2. Subclass `MacSpaceModuleEntry` with an `@objc(...)` name, return a `MacSpaceModule` from `makeModule()`, and set the class as the
   bundle's `NSPrincipalClass`.
3. Write `Manifest.json` (see an existing one) and a `Bundle/Info.plist`.
4. Add the targets to `Package.swift`: a dynamic library product **named exactly like the folder** (`Assemble.sh` walks `Modules/*/` and
   packages `lib<Folder>.dylib`), and, for root operations, a static `…Privileged` target that is also linked into `MacSpaceHelper`.
5. Keep the module's logic testable without a Mac: the screen builders are pure functions of a snapshot.

## The helper: making sure it always works

Registration is the most fragile part of the app. What is in place, and what to check by hand:

**In place (all covered by tests unless noted)**
- The app registers itself with Launch Services at launch and before installing the helper, so a hand-copied app reaches "requires
  approval" instead of "not found".
- "Requires approval" is treated as a normal wait, with an "Approve in Settings" button.
- At launch the app compares the helper it is running against the one in the bundle and re-registers on a mismatch or when nothing
  answers (covers updates). *Exercised on a development Mac; not yet through a real Sparkle update.*
- A failed XPC connection is replaced on the next call.
- The Settings row says why the helper is "not found" (quarantine, translocation, wrong folder, missing plist) and what to do.
- The System Data banner says "could not be reached" separately from "macOS did not let the helper read".
- Local builds use a stable signing identity, so Full Disk Access survives rebuilds.

**Check before every release, on a clean macOS 27 VM (not the development Mac)**
1. Download the DMG, drag the app to Applications, open it. No Terminal commands should be needed.
2. Settings → Permissions: the helper row reads "Approve in Settings"; approve it; the row reads Granted.
3. System Data: the three root-only locations are measured (no "helper could not be reached" banner).
4. Replace the app with the next build (as Sparkle does), relaunch: the helper still answers; `MacSpaceCli helper --ping` reports the
   new binary.
5. Siri page shows the virtual machine message (VMs only).

**If the helper fails.** `MacSpaceCli helper` prints the status and the likely reason; `helper --register` prints the registration
error; `sudo sfltool dumpbtm | grep -i -B2 -A14 macspace` shows macOS's own record (look for the disposition and the app's path).
`sudo sfltool resetbtm` plus a restart clears all background items. Use it on a throwaway VM only.

## What is verified, and what is not

**Verified (automated):** 280 tests: contract and registry behaviour, screen builders, parsers, the helper service and XPC round
trip in-process, the lazy channel, crash-isolation subprocesses, the version-store cleaner with a fake `launchctl`, update gating.

**Verified by hand:** the three modules load and answer from the assembled app; System Data totals within about 1 GB of System
Settings; helper install, approval and measurement of root-only locations; deletion of the version history; Debloat reading live
state; all of it on macOS 27 build 26B5091g, and the helper install and Siri message on 27.0.1 in a VM.

**Verified 2026-10-03 (27.2, 26B5091g, `Scripts/TestUntested.sh release`):** Developer ID signature with the hardened runtime,
notarization and the stapled ticket (Gatekeeper accepts the app), the helper installed from a notarized build and answering.

**Self-tested 2026-10-03 (27.2, 26B5091g, `Scripts/SelfTest.sh`, 28 passed):** the helper answering the CLI; CacheDelete's
self-test and every service; every module's page and tile; every Debloat control that is not a policy switched off and back on
through the app's code, checked against the page and the stored values, and left as found.

**Not verified:** Gatekeeper on a clean Mac with a notarized build; a Sparkle update from an older build (needs a published release
and SPARKLE_PUBLIC_KEY); the helper through an update; the automatic release of leftover Apple Intelligence models and the purge after switching it off;
Debloat profile approval beyond the development Mac; analytics on a release build (`telemetry.diagnostics`, the only control
marked "Not tested"). The policies were tested in the research (profile-policies-2026-09-29: every key forced once approved).

**Plain settings are written as System Settings writes them** (research, mechanism ladder #1): `CFPreferences` on the owning domain,
then the setting's change notification. Improve Siri & Dictation posts `kAFPreferencesDidChangeDarwinNotification`, read from
AssistantServices at run time (the research found that constant in results/cp107; on 26B5091g its value is its own name).
Self-tested 2026-10-03 (26B5091g, 29 passed): the notification is posted on every write, off and on.
Personalized ads and the ad identifier need no notification (self-tested 2026-10-03, 26B5091g): their owners, adprivacyd and
promotedcontentd, are started by launchd on demand and read the value then. A running adprivacyd logged nothing on the write or on
either candidate the frameworks hold (ADConfigurationDidChangeNotification, kADIDManager_ChangedNotification), and its log shows
cfprefsd's generation check ("Contents Need Refresh"), so it gets the saved value on its next read.

**One profile for every policy** (2026-10-06). `com.macspace.policies` holds every policy switched off (`DebloatEngine.profileWork`).
Any change stages it again under the same identifier and opens System Settings on it; approving it replaces the installed one. A
policy switched back on stays enforced until then. The last one switched back on removes it through the helper, and profiles of
earlier versions go through the helper once the one profile holds what they did. The page reads again whenever MacSpace becomes
active, and forced values are read from `/Library/Managed Preferences`, so an approval shows at once. Verified on the development Mac:
the installed profiles and their values are read correctly; the full approve-and-clean-up round has not been watched end to end.

**No build gating.** What was tested on one macOS build counts on every build: CacheDelete is used wherever its functions exist
(crashes are contained in the CLI child process, and a purge first checks that the service filter is honored), and a Debloat control
measured on any build counts as tested. Untested controls work and say "Not tested", so they get tested.

## Releasing

The release pipeline (build, sign with Developer ID, notarize, staple, Sparkle signature, appcast, draft GitHub release) lives in a
separate **private** repository so the signing identity and keys never become public. It builds this repository at a given ref. A
release is only ever created as a **draft**; publishing is a manual step on GitHub.

Still needed from the maintainer before the first release: notarization credentials, the Sparkle EdDSA key (back up the private
half; losing it strands every installed copy), a repository token for publishing, a license for this repository, and a macOS 27 runner
if releases should run from GitHub Actions.

## Conventions

- Folder names start with a capital letter.
- Commits are authored by the maintainer's own account and carry no tool attribution lines.
- Experiment results go to the private repository's `results/` folder; findings that matter for everyone go to
  [Research.md](Research.md) with an evidence label.
- Do not change the bundle identifiers (`com.macspace.*`): Full Disk Access, the helper approval and update signatures depend on them.
- Anything new that touches a private Apple interface needs a per-build guard and crash isolation like CacheDelete's.

## Open work

- Notarize a build and run the clean-VM checklist above, then a Sparkle update test.
- Cache cleanup for other apps is deliberately not in System Data (`~/Library/Caches` is listed, not cleaned), except the Chromium
  and Electron caches in Application Support, cleaned while the app is closed (asked for on 2026-10-06). The rest would be its own
  module.
- Remove Downloads (Other System Files) has not been run on a real cloud folder yet: check it with OneDrive, then iCloud Drive.
- Siri screen: a button for "remove orphan subscriptions" through the helper (today it points to a command that needs `sudo`).
- Debloat in a virtual machine still shows controls that cannot take effect there.
- Per-document breakdown of the version history, so users can choose what to delete.
- System Data reads higher than Settings (51 against 44.5 GB here) because Settings over-counts Apple Intelligence and takes the
  difference from System Data (Research, section 1); decide whether the page should say so.
- Time Machine's local snapshots are not measured.
- Documentation beyond this folder (README, user guide) once the first release exists.
