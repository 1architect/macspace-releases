# Handoff

Everything someone needs to pick this project up: what exists, how to build and test it, how it is put together, what is verified,
and what is still open. Findings about macOS itself are in [Research.md](Research.md); the research that came before the app is summarized in [Original-Research.md](Original-Research.md).

## What MacSpace is

**A System Data and Apple Intelligence cleaner for macOS 27.** It shows what fills System Data and frees what is safe to delete, and
it switches Apple Intelligence off and deletes the models macOS keeps on disk afterwards. Everything else it does serves those two
jobs.

Inside, each job is a **module**, a separate plug-in that describes its widgets for the app to draw. Four ship today:

| Module | What it does |
|---|---|
| **System Data** (the core) | Explains what fills System Data, frees what is safe (system caches, old reports, unused system assets), deletes the document version history on request, and guides the manual cleanup macOS and other apps own. |
| **Siri & Apple Intelligence** (the core) | An off-switch for Apple Intelligence, a background watcher, and release of the models macOS keeps afterwards. Does nothing in a virtual machine. |
| **Other System Files** | Space outside System Data that macOS counts as purgeable: what it is, per purge service, and freeing the files apps marked purgeable now instead of when the disk is nearly full. |
| **Debloat** (extra) | Twelve switches for analytics, ads and background data collection macOS lets you control, and a background watch that switches off again what macOS turns back on, with a notification. |

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
| `Scripts/` | `Assemble.sh` builds the `.app`; `Localize.swift` writes the translations; `TextCatalog.swift` and `SelfTest.sh` support them and the checks. |
| `Packaging/` | The helper's launchd plist template. |
| `Tests/` | One test target per area. |
| `Docs/` | This folder; `Screenshots/<language>/` holds the README images. |
| `ReleaseNotes/` | `<version>/<language>.md`: the notes on each GitHub release and in the app's update window. |

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
`DEV=1` builds with the development tools (the default for a `-dev` version, which is what a local build is named after the last
release), `DEV=0` without them (a release); `OUT_DIR` builds somewhere else than `Build/` (`OUT_DIR=Build/Dev` keeps a development
build apart from the app that gets installed); notarization is on by default with a Developer ID identity, and `NOTARY_PROFILE=`
turns it off.

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
   section) and a summary widget for the Home tile. The app draws them. Module pages use grouped SwiftUI rows whose shades and separators belong to each row, so the legend, headings and rows can cascade together. Native Form group backgrounds stayed visible during row transitions. Loading and cleaning share one visibility controller; tile zooms hide the entire page until settled. Actions come back as `ActionRequest`s; the app checks the
   action's `requires` permissions and shows its confirmation first. A row's subtitle is a count after its title, and its facts are pills
   (`Row.badges`) right after it; its detail and steps, a section's subtitle and a list's footnote open from a small (i) in a Liquid Glass popover (`InfoButton`).
   Give an item a description only when the title is not enough (something the user can do, or a risk), in one or two short
   sentences: no (i) is drawn without one. Rows are drawn without symbols, and modules are named without theirs. A row with
   `children` is a group that opens a page of its own. A row with `paths` gets a folder button beside its (i) that shows its files
   in the Finder (`RevealTarget`); list only places the user can open. A block of the page's hero with `items` (`UsageSegment`)
   opens a page of them through the same stack as a group (`ScreenView.row(_:in:)`), with the same page change and Back; a tile's
   blocks carry none, since tiles are saved. System Data and Other System Files use both; Siri and Debloat have no files to show
   and no hero.
3. **Switches show the feature.** On every toggle, on means the feature runs and off means MacSpace switched it off. Debloat follows
   this too; keep it for new modules.
4. **Caching.** When no window is visible, the host releases screen row trees and invalidates scan caches, keeping only tile summaries for the menu bar. Reopening restores the screen even if its last read was recent (#11). Each module keeps one shared scan (`…Store`) so the Home tile and the page do not scan twice. The Refresh button
   calls the module's `invalidate()` first.
About MacSpace is the app menu’s About command (also in the status menu), using MacBat’s native alert layout with version, author, GitHub and uninstall. It is not a Settings section. Module contract version 3 adds the uninstall hook. Modules implement `prepareForUninstall(context:)` to restore reversible changes before the helper is removed. The host calls disabled modules too; failures keep the app installed. Siri restores its saved language and voice, Debloat reverts journaled settings and removes its own profiles. Cleaners use the default no-op because freed files cannot be restored.

5. **Privileged work** goes through the helper. A module's `Privileged/` library declares named operations (`siri.orphan-subscriptions.*`,
   `debloat.*`, `systemdata.measure`, `systemdata.versions.delete`); `Helper/MacSpaceHelper.swift` registers them. The helper accepts
   only clients that satisfy a code-signing requirement passed on its command line and refuses to start without one.
6. **Crash isolation.** Private Apple calls (CacheDelete) run in the CLI as a child process.
7. **Settings.** General (theme, appearance, a row opening the Permissions page, what closing the window does, login), Updates
   (automatic checks, the version and Check Now), Cleanup (automatic cleanup and the history), Notifications, the module switches,
   options and background tasks per module, and last the macOS release. Sections are built directly in
   `SettingsView`; wrapping them in custom views inside a `ForEach` made them render inside the wrong card.
8. **Look.** A theme is a night and day pair of palettes (`PaletteScheme.themes`); Settings chooses the theme and whether it follows the
   system, or stays night or day. Whatever needs the user is drawn in the action color (amber, lime on Ink); the app has no red.
9. **Menu bar.** An `NSStatusItem` (`StatusItemController`): a click opens the app, a right click opens its menu (each module with
   its tile's status, opening its page; then Settings…; then Open Panel and Quit). `AppRouter` opens the window from outside it and
   brings it in front of the app in front: from the icon, the cooperative `NSApp.activate()` was refused and the window stayed
   behind (2026-10-07), so it uses `activate(ignoringOtherApps:)` and orders the window front regardless; when no window has been open since launch it
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
    Platform: used, less macOS and every other category, each a fixed set of places read from Settings' code; Research, section 1). Nothing has to list what System Data holds, so whatever a Mac has that MacSpace does not know
    still lands in it. The page's items are only the breakdown: what they leave out of the total is a "Not identified" block, so a
    rule that goes wrong shows as a measured amount instead of a wrong total. The same places decide which items are System Data
    (`SystemDataItem.elsewhereBytes`). The debug command `settings:<file.json>` writes the reading.
13. **Onboarding** (`Onboarding`): on a new install, in place of the dashboard, one screen per missing permission (Full Disk Access,
    the helper, notifications), then a last one saying how much can be freed; each an animated symbol, a headline, one line and one
    button. No welcome screen: it starts with what MacSpace needs. Steps already granted are left out (all granted: no onboarding);
    the symbol answers when a permission arrives. The step is kept across the relaunch System Settings asks for after Full Disk
    Access. Installs that ran before onboarding existed skip it; `open -a MacSpace --args --onboarding` shows it again.
14. **Languages.** English, Portuguese (Brazil), French, Spanish, German, Simplified Chinese (zh-Hans), Japanese (ja) and Korean (ko). The translations live in `Localization/<Table>.json`
    (`App`, and one per module), each English text, exactly as the code has it, mapped to its translations in the order declared by `Scripts/Localize.swift`;
    `swift Scripts/Localize.swift` writes them as `<language>.lproj/Localizable.strings` in `App/Resources` and in each module's
    `Bundle/` (Assemble.sh copies them), and stops if a translation drops a placeholder. `--check` also builds with the compiler's
    string extraction and lists every text the code shows that no table has: run it after changing any text. In the app, SwiftUI
    literals are localized by themselves and other text goes through `String(localized:)`; a module's text goes through its own
    `loc(...)` (`Support/Localization.swift`), which reads the module's bundle, and the names in Debloat's catalog (shared with the
    helper) through `locKey`. Manifest names, options and tasks are looked up in the module's bundle when the app reads them
    (`ModuleScanner.localized`). A saved tile is only shown in the language it was saved in. Only the developer tools, the CLI and
    the helper stay in English.
15. **Design tools.** The Design menu and its windows (Shader Studio, Widget Type, Text Editor, Screenshots) are compiled only into
    development builds (`MACSPACE_DEV`, set by `DEV=1`). A release has no menu, no windows and no flag that brings them back, and it draws
    every Design menu setting at its default whatever a development build left in the defaults (`DesignSettings.tool`). In a debug build
    (`swift build`), `MACSPACE_DEBUG=1` turns on `DebugRemote` (window capture, navigation, and `du:` which sizes folders with the app's
    own Full Disk Access); it is compiled out of release builds.
16. **README screenshots.** `Docs/Screenshots/<language>/` is made by the Screenshots window of a development build (Design menu, ⌥⌘S),
    which photographs the window page by page at the screen's full resolution and saves 8-bit RGBA PNG files with no palette, so soft
    gradients do not band (an optional one-level dither breaks up a step that is left). For all of them at once, with the shipped look and
    the language of your choice, run from the repository:
    ```bash
    for language in en pt-BR fr es de; do
      Build/Dev/MacSpace.app/Contents/MacOS/MacSpace --capture-screenshots Docs/Screenshots/$language \
        -AppleLanguages "($language)" -AppleLocale "${language/-/_}"
    done
    ```
    Quit the installed MacSpace first. Do not run the files through an image optimizer that reduces colors.

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

**Verified 2026-10-06 (27.2, 26B5091g):** a 1.0.0 build with the macOS 27.0 minimum signed, notarized and stapled by
`Scripts/Assemble.sh`; Gatekeeper accepts it (`spctl`: Notarized Developer ID).

**Verified 2026-10-07 (27.2, 26B5101f, and GitHub's `xcode-27` runner):** CI passes on a clean hosted Mac. Its first runs found
three tests that only passed on the development Mac: a size written with this Mac's decimal comma, Apple Intelligence records the
runner cannot list, and a Debloat flag 26B5101f no longer declares (`GenerativeLearningPlatform/PlatformDaemons`: it reads
disabled and hybridsearchd's launchd plist still tests it, so the other two flags decide; not measured with a reboot). It also
found that a Mac without the models showed their size as unreadable instead of zero (fixed in `ModelDescriptors.usage`). The
release pipeline built `v1.0.0-rc.2` from its tag: app and disk image notarized, the update signed with MacSpace's own key, the
feed with notes in five languages. `v1.0.0-rc.1` is a tag without a release: its build stopped at those tests.

**Self-tested 2026-10-03 (27.2, 26B5091g, `Scripts/SelfTest.sh`, 28 passed):** the helper answering the CLI; CacheDelete's
self-test and every service; every module's page and tile; every Debloat control that is not a policy switched off and back on
through the app's code, checked against the page and the stored values, and left as found.

**Not verified:** Gatekeeper on a clean Mac with a notarized build; a Sparkle update from an older build (needs a published release
and SPARKLE_PUBLIC_KEY); the helper through an update; the automatic release of leftover Apple Intelligence models and the purge after switching it off;
Debloat profile approval beyond the development Mac; analytics on a release build (`telemetry.diagnostics`, the only control
never tested). The policies were tested in the research (profile-policies-2026-09-29: every key forced once approved).

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
measured on any build counts as tested. Untested controls work; the page shows no badge for them (removed 2026-10-07).

## Releasing

How a version is tagged, built, tried, published and stopped is in [Releasing.md](Releasing.md). In short: the release commit
dates the [changelog](../CHANGELOG.md) and adds `ReleaseNotes/<version>/` in the five languages, a tag `vX.Y.Z` is pushed, and the
**private** repository's `Release.sh` builds that tag (sign with Developer ID, notarize, staple, Sparkle signature, appcast) into a
**draft** GitHub release; its `Publish.sh` publishes the draft, which is when installed copies are offered the update, and updates
the Homebrew cask. The signing identity and keys never touch this repository. The project is MIT-licensed ([LICENSE](../LICENSE)).

The minimum is macOS 27.0 everywhere (`Package.swift`, the three packages, `Info.plist`, every module's `Info.plist` and
`Manifest.json`, the icon's deployment target), since 2026-10-06. MacSpace's own Sparkle key exists since 2026-10-07, in the
maintainer's keychain under the account `macspace` (MacBat's key is the default account and must not sign MacSpace); its public
half is `V/z4pnoOR4BnUss4chVEq0asKI1UssXuWoNHuuH+Jik=`, which release builds carry as `SUPublicEDKey`. MacSpace 1.0.0 was
released on 2026-10-07: GitHub release `v1.0.0`, the update feed, and the cask `macspace` in `1architect/homebrew-macspace`.

## Conventions

- Folder names start with a capital letter.
- Commits are authored by the maintainer's own account and carry no tool attribution lines.
- Experiment results go to the private repository's `results/` folder; findings that matter for everyone go to
  [Research.md](Research.md) with an evidence label.
- Do not change the bundle identifiers (`com.macspace.*`): Full Disk Access, the helper approval and update signatures depend on them.
- Anything new that touches a private Apple interface needs a per-build guard and crash isolation like CacheDelete's.
- Every page follows the [interface rules](../CONTRIBUTING.md#interface-rules): short texts for laymen, each item listed once,
  largest first, facts as pills, and Free as the only verb for freeing space.

## Open work

- Notarize a build and run the clean-VM checklist above, then a Sparkle update test.
- The caches page (System Data › Caches you can free, `CachesPage`) has not been clicked through yet: check a box and the header
  boxes, then that the main Free button frees the saved choice.
- Remove Downloads (Other System Files) has not been run on a real cloud folder yet: check it with OneDrive, then iCloud Drive.
- Siri screen: a button for "remove orphan subscriptions" through the helper (today it points to a command that needs `sudo`).
- Debloat in a virtual machine still shows controls that cannot take effect there.
- Per-document breakdown of the version history, so users can choose what to delete.
- Settings counts about 3.9 GB of the Data volume as macOS, and MacSpace's clone-aware items still exceed its remainder by 0.62 GB (Research, section 1): both are stated on the page and unexplained.
- Time Machine's local snapshots are not measured.
