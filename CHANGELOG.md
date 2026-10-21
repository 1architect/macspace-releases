# Changelog

All notable changes to MacSpace are recorded in this file.

The format follows [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/). MacSpace follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- System Data's total matches System Settings again: Settings counts everything in your Library's Application Support folder under
  Applications, and MacSpace counted it in System Data, about 8 GB more on our Mac (#35). Settings' figure still moves by a GB or
  two on its own between readings, as macOS updates its estimate of the space it can free.
- iPhone and iPad backups count once, in iOS Files: they are inside the Application Support folder that Applications now counts,
  so they came off System Data twice, and with a large backup System Data could read 0.
- System Data no longer reads 0 GB when copies of large files sit in two categories, such as a game in an app's Application
  Support folder copied into Documents. APFS stores such a copy once until one of them changes, and MacSpace counted it in full in
  both, about 58 GB too much on our Mac.
- Settings' pop-up menus are drawn as macOS draws its own, the chosen option with no button shape behind it, and the Recent
  cleanups row no longer shows how many cleanups there were (#36).
- Apps are named in every list and confirmation, never by their bundle identifier: "Quits OneDrive, Affinity and CodexBar" instead of
  "com.steipete.codexbar". The name comes from the installed or running app, from the app an extension or helper belongs to, and
  failing that is made readable from the identifier.
- An app's cache folders in your Library's Caches (CodexBar's `CodexBar` and `com.steipete.codexbar`) are one row on the caches
  page, with their sizes added and Free clearing all of them, instead of two rows for the same app.

## [1.1.4] - 2026-10-20

### Changed

- MacSpace uses less memory than in 1.1.3. By our estimate from tests on one Mac (macOS 27.2): its peak at launch is about 45%
  lower (about 95 MB instead of 175), it uses about 15% less with its window open and idle, and about 25% less with the window
  closed while it runs in the menu bar. The momentary jumps of 50 to 80 MB while tiles changed are gone. Your figures depend on
  your Mac and what the modules find on it.
- Tile captions that change their words no longer make MacSpace jump by up to 80 MB for a moment: the words roll in and out as
  before, drawn the ordinary way. The jumps were most of the 200 MB and more seen at launch.
- Numbers roll exactly as before, without piling up memory: every roll drew its digits again at each frame, and Core Graphics kept
  an image of each one, up to 150 MB and more while the modules read at launch. MacSpace now keeps that cache small; a digit no
  longer kept is simply drawn again.
- Tile captions keep their exact size while a tile moves, without keeping a font for every size they pass through.
- When its window is closed, MacSpace lets go of the window's pages at once while it keeps running in the menu bar or in the
  background, and builds them again when the window is next opened, which then opens as it does at launch.
- Long lists no longer cost memory for rows you cannot see: a module's page and Settings make only the rows on screen. Opening
  Settings › Recent cleanups took about 170 MB with 260 cleanups on our Mac, and a module page of 260 rows as much; both now take
  about 11 to 14 MB.
- Recent cleanups keeps the last 100 cleanups one by one; older ones still count in Freed in total.
- Debloat's background task is now called "Disable automatically if changed".
- Pill text, on text pills, pill buttons and row flags alike, is now in medium weight, from one shared font.

### Fixed

- In Settings, a row's switch and menu now arrive and leave with the rest of their row when the row cascades in or out, instead of
  fading in place on a timing of their own.
- The window's shadow grows in with the window as it opens, instead of showing at its full size around the smaller window.
- A list's rows no longer darken where they overlap while one slides in or out: the list's shade grows and shrinks as one shape.
- Every module now says "Freeing in the background" in the same grey pill while MacSpace frees space by itself: Siri & Apple
  Intelligence said "Freeing space", and System Data and Other System Files showed a darker flag in place of Free.
- A row's Open button no longer flashes "Working" while it opens System Settings.
- A row's Free keeps its grey look while it works and with its result; only a result that asks something is orange.
- A row's (i) and folder always come first after its title, then its pills and its button, so a pill that comes in place of Free
  appears where Free was.

## [1.1.3] - 2026-10-19

### Fixed

- The window is placed like any other macOS window: **Fill**, **Window › Move & Resize** and dragging it to a screen edge put
  its glass exactly where macOS places it, with no gap, and the window's own Maximize does the same.
- The window's shadow moves with the window while it is dragged, and the menu bar no longer shows a dark line when the window is
  near it.
- Siri's speech models that nothing uses any more (left behind when Siri's language changed) are now freed when the cleanup runs,
  instead of staying for days with **Waiting for macOS**. If macOS still keeps a switched-off feature's models, MacSpace asks
  for a restart once, and after it says **Kept by macOS** instead of waiting without end.
- Buttons in rows, in Settings and in modules, are the same flag as a module row's **Free**. With a figure or a switch on the
  right of the row, the button stands after the row's title; without one, it is on the right. **Check Now** is on the
  automatic updates row. **Granted** and the other
  Settings pills are the same height as every other pill. **Recent cleanups** shows the total freed as its own row.

- **Check for Updates** with nothing new is in the app's language again when the running version is newer than the latest
  release, with the same short sentence as when it is the latest.

### Changed

- Release tags are signed (Docs/Releasing.md).

## [1.1.2] - 2026-10-19

### Fixed

- A row's warning pill (**Cannot be undone**) no longer truncates and comes back over and over while the row's Free works, and
  the size on the right no longer wraps onto two lines: the row hands out its width in a fixed order instead of even shares.
- A pill short of room narrows smoothly over its text, its end fading, instead of losing a letter at a time, so the (i), the
  folder and the Free flag beside it glide as the flag grows or shrinks.
- A second Free clicked while another row's cleanup runs shows at once that it is working and runs next, and each row keeps its
  own result: the first row's **Freed** no longer disappears when the next one starts.

## [1.1.1] - 2026-10-19

### Added

- **Siri**, **Spatial Photos** and **Call transcription** switches in Siri & Apple Intelligence. Each turns its feature off,
  saves the original settings and deletes the models it leaves on disk. While MacSpace is open, it deletes them again if macOS
  asks for them again. Call transcription needs a restart and installs no profile. Switching a feature on restores what MacSpace saved.
  They work on every macOS 27 release, with Apple Intelligence on or off. While Apple Intelligence is on, MacSpace deletes the
  models only while macOS is downloading nothing.
- The Siri & Apple Intelligence tile and each switch show the size of the feature models on disk, as for Apple Intelligence,
  and keep showing it while they are switched off and macOS still has them. Switches can show a size beside them (`ToggleRow.trailing`).
- The Siri & Apple Intelligence page's main button works like Debloat's: it frees the models when there are some to free, else
  turns off every switch still on, else turns them all back on.
- **Unused system assets** in System Data also releases unused language data.
- Simplified Chinese (#8), Japanese and Korean (#9), throughout the app and all four modules, and the README, Privacy Policy, Security
  Policy and License in the three languages.
- **About MacSpace**, in the application and menu bar menus, with the version, GitHub and an uninstaller that restores each
  module's settings before it removes the helper and moves MacSpace to the Trash (#15).
- Scans show their progress in the action button and on the Home tiles.

### Changed

- Freeing a single row checks only what that row freed, without scanning the whole module again. Pages stay usable while they
  refresh, and cloud files use the same cleanup in System Data and Other System Files.
- The **All done** page stays a few seconds, without a countdown, so the freed space can be read before it goes back. The wait
  starts only once the page has its new figures.
- Debloat's **Siri AI** is now **Siri AI search**, with a description that says it stops the search app and leaves Siri itself
  to the Siri page.
- Homebrew and `/usr/local` explain what they hold and what MacSpace frees there.

- The design tools' text catalog loads only when its window opens, not for as long as MacSpace runs.
- **Phone features** is now **Call transcription**, in every language and in the documentation.
- Every (i) is a short, static description of the item: no sizes, counts, dates, file lists or live state, five lines at most.
  What a state means now is on its pill, as a hover tag (`Badge.help`); `InfoText` in the SDK sets the rule and the app enforces it.
  Debloat's verification notes, the Siri page's switch states, cloud folders with their file counts, Time Machine snapshot dates and
  the old reports count moved out of their (i).

### Fixed

- The documentation matches the app: Debloat's **Siri AI search**, five policies (six on a macOS beta), the uninstaller in
  **About MacSpace** (the Security Policy said there was none) and the Privacy Policy's date. The release pipeline lists all eight
  languages for release notes.
- No restart is asked for a feature switched back on: it keeps its models.
- A row's pills stay quiet while its own Free flag works, so the two no longer pulse orange side by side.

- Debloat's analytics switches no longer say **Not verified** when macOS logged no decision to read: they keep the settings they
  wrote and read back, and only a decision to send diagnostics shows a pill.

- A row's **Free** flag no longer pushes the buttons beside it around while it cleans, and no longer narrows and widens with
  every progress message.
- System Data no longer shows an **Unused system assets** row with no size, whose Free freed nothing.
- A switched-off feature no longer says **Waiting for macOS** once its models are gone: the small catalog records macOS keeps
  with no owner no longer count, and no purge is asked for them every five minutes.
- Siri & Apple Intelligence asks for a restart when only one frees a feature's models (**Restart required**, and **Restart to
  free** as the page's main button), through macOS's own Restart dialog (`SystemRestart`).
- **Home page alerts**, a new setting, first among the module's: off, the Siri & Apple Intelligence tile neither shows its mark
  nor takes the large spot for models a switch would free. The 15-minute Apple Intelligence check runs by itself, with no switch
  (`BackgroundTaskDefinition.hidden`), and the other check is **Free switched-off features' models automatically**.
- The Siri & Apple Intelligence tile's switch is on while any of the page's switches is, and switches them all off or on. The page
  titles its lists **Models** and **Sync to other devices**.
- Every list and section title is drawn as System Settings draws its grouped lists, semibold in the text's color, in Settings and
  on every module page alike.
- When macOS's own services keep a switched-off feature's models open, the **Waiting for macOS** pill says so on hover, and that
  they go when those services stop or after a restart.
- Switching Siri off frees its 2.4 GB of understanding models again: Siri's language hold now uses another of macOS's language
  aliases, which MacSpace recognizes from macOS's own definition, and a feature counts as clean only once its models are gone.
- Rows, legends and pages arrive and leave in one steady cascade, without jumps after a cleanup (#23).
- Numbers and words in captions, buttons and **All done** change smoothly, without overlapping, cutting off or leaving the tile
  (#19, #22).
- A finished scan no longer leaves the Siri & Apple Intelligence button showing Loading.
- Analytics shows Not verified when macOS gives no clear evidence, and its explanations are translated.
- Dialogs keep their icon, heading and message aligned left.
- Tile attention marks stay centered in their corner (#17).
- Zoom and macOS's Fill fit the window to the screen and hide its shadow while it fills the screen. Inactive window controls fade
  correctly.

## [1.1.0] - 2026-10-13

Hi! I'm Gio, MacSpace creator.

I was not expecting MacSpace to be so well received by the community, so thank you so much for your support!

As we move forward with the project, today we introduce an important new feature: app cache cleaning.

Currently there are numerous paid, free and open source solutions for cache cleaning.

MacSpace takes a new approach on the matter: instead of individual app guided development, the default MacSpace backend uses an app agnostic solution based on the main available frameworks for app development on MacOS.

And instead of cleaning everything up just for the sake of big numbers, MacSpace suggests to erase only the things that will actually not come back to eat your disk just after cleanup. But of course if you want you can delete everything, just make sure to check all apps you'd like to reset.

And because there are lots of great solutions on the market, you can also choose to use them instead of MacSpace default solution. When cleaning MacSpace will point you to open your favorite app. Or to use none at all too. Just remember to select the preferred one in settings.

We are also deprecating two debloat toggles that MacOS does not recognize anymore and were causing issues with the mail app.

For dessert, lots of bug fixes and refinements! See you soon.

### Added

**System Data**

- **Caches you can free**: one page for the caches MacSpace can free, with developer caches, a saved choice and select-all. The caches
  of apps are judged by their files' own dates and their app's last launch (no list of apps): those unchanged for a month whose app
  has not been opened for as long, or is not installed, come checked; the others are listed unchecked, and those in use say that they
  come back. Apple's caches and folders with media or documents named by people are never listed.
- With Full Disk Access, the caches that App Store and other sandboxed apps keep in their container are listed there too, by the same
  rules, and go only while the app and its extensions are closed.
- The caches of **open apps** can be checked too. **Free** names those apps ("Quits Enscape and WhatsApp."), quits them (an app can ask
  you to save, and you can cancel) and frees their caches. Automatic cleaning never quits an app. A cache kept by a program that is
  not an app in the Dock (a command-line tool, a plug-in's renderer) says **In use** and is closed first.
- Developer caches that Purge frees and MacSpace did not: Xcode's cache, documentation and test devices, Playwright, Puppeteer,
  Corepack, Yarn Berry, Deno, Composer, NuGet, Dart packages, Android's build cache, older versions of Claude Code and Cursor Agent, and
  every other folder in `~/.cache`.
- **Homebrew** row: runs Homebrew's own `brew cleanup` (and, with a second button, also deletes every download), as you, without
  autoremove, auto-update or analytics.
- **Trash** row: frees the Trash for good, or shows it in the Finder.
- **System log** (about 2.9 GB here) can be freed with Apple's own `log erase`; **Symbols for crash reports** once they reach 50 MB;
  **Old app copy**: the copies macOS makes of an app when it checks it, once the app was updated. Each has its own button, cannot be
  undone, and is never part of Free or automatic cleaning (the page's **Free** also erases the system log).
- Wallpaper and screen saver downloads that macOS left unfinished (they can grow to hundreds of GB) have a row of their own.
- **Protected by macOS**: the part no folder accounts for is named once everything MacSpace can measure is measured, and opens a page
  of what macOS keeps closed to every app.
- **Cache cleaner** (Settings › System Data): pick who frees the caches, MacSpace or CleanMyMac, Mole, OnyX, Pearcleaner, Purge or
  Sensei when installed. **Free caches** turns the caches page off.
- A click on a block of a page's chart opens a page of the items it is made of (System Data, Other System Files). A folder button
  beside a row shows its files in the Finder.

**Other System Files**

- **Time Machine snapshots** are listed with how many there are and the space macOS says they hold. **Free** deletes all but the newest
  and the one the next backup starts from, never while a backup runs.
- **Time Machine backup disks**: a connected disk opens a page of its backups, newest first, to choose old ones to free; the latest
  always stays.
- The purgeable app files say how much of them is the symbols for crash reports.

**App**

- Freeing space looks the same everywhere: the main button says **Freeing space…** and fills as the work advances, rows leave the page
  as each is freed, and **All done** comes in as a page of its own with what was freed counting up under it. While a module reads the
  Mac, the page's **Loading…** button fills as the scan advances.
- The window keeps its size and place between launches and opens on the desktop where you click the menu bar icon. The whole dashboard
  moves the window. On the dashboard, the ✕ grows into a glass pill with **Minimize** and **Maximize** when you point at it.
- Tiles: titles in SF Pro Display, with a status line in light weight; a tile says what its module is cleaning, and how far it is,
  while a cleanup runs; the attention mark sits in the bottom-left corner. Charts are arranged at their own shape again, a tile draws
  at most 4 blocks and names the one under the pointer.
- Confirmation windows have one shape: left aligned, a title in at most two lines and a description in at most two.

### Changed

- System Data is 3× faster (27.4 s to about 8.4 s on the development Mac, same figures), and the folders only root can read are
  measured again (they all read 0 bytes). A helper that cannot start no longer hangs the app. Idle CPU is lower.
- Free now lists the largest first. Pills replace notes, and **Free** is the only verb.
- Confirmations are short: the title asks, and one line says only what you would not expect.
- Resizing the window: the tiles follow it without leaving and coming back, their blocks stretch without re-arranging, and their text
  changes size at most once. The window resizes from a band across the glass's edge instead of a thin line outside it.
- Clearer texts: version history's detail ("Only keeps the latest version."), the system log's ("Erase Console records used for
  troubleshooting."), the Siri tile in a virtual machine, **Clean automatically**, and the retry when nothing could be measured.
- Settings: a **System** section with the macOS release; the (i) balloons follow the night or day look chosen in MacSpace.
- Debloat: the Siri AI switch says what stays on (Apple Intelligence and its other features).

### Removed

- Debloat: the **Generative search indexing** switch. It stopped Mail search from working, with or without Apple Intelligence
  ([#6](https://github.com/1architect/macspace-releases/issues/6)). If you had switched it off, MacSpace switches it back on by itself
  (with the helper); restart your Mac to finish.
- Debloat: the **Apple Intelligence features** switch. Apple deprecated its policies and their effect could not be verified; the
  Apple Intelligence switch on the Siri & Apple Intelligence page turns these features off. Where it is still applied, MacSpace removes
  its policies by itself (they made macOS treat Apple Intelligence as restricted, hid it in System Settings and stopped its download).

### Fixed

- System Data: a cache is never deleted while a command-line tool that owns it, a helper of its app or any other program is using it,
  and freeing caches no longer quits Siri or any other part of macOS (only apps you see in the Dock or menu bar). WhatsApp's cache
  was never freed because its notification extension counted as the app.
- System Data: files reached by several hard links were counted once per path (1.49 GB too much for Spotlight's store alone), and
  Apple's container caches that macOS counts as purgeable were counted in full, so the listed items added up to more than System
  Settings' figure. Small Apple containers and parts of `~/Library` were left out of every group; they are listed now.
- System Data: a file deleted while a process holds it open made the check for open files answer "unknown", so Clean deleted nothing.
  A cache is renamed, then deleted, so an app that starts meanwhile never finds half of one.
- Debloat: a policy that Screen Time or another profile sets is no longer shown as switched off by MacSpace ("Set by another
  profile"; Disable all leaves it out).
- Apple Intelligence downloads are no longer cut short: while Apple Intelligence is on, MacSpace never asks macOS to delete system
  assets, through which its models download and update.
- Charts drew what can be freed larger than parts many times its size; its block no longer exceeds the part just above it.
- Siri & Apple Intelligence: the line about the models showed on no tile.

### For module authors

- `Row.selection` lets a group's page offer checkboxes and a button titled with the chosen rows' total (`Selection.choices`,
  `Selection.noteNames`, `Selection.note`); `Row.paths` and `UsageSegment.items` list a row's files and a block's items;
  `Action.workingTitle` and `ActionProgress.finished` drive the freeing button; `MacSpaceModule.screen(context:progress:)` with
  `LoadProgressRelay` reports a scan's progress; `OptionDefinition.under` and `OptionChoice.apps` declare options such as the cache
  cleaner; `Tile.figure` puts a figure on its own line.

## [1.0.3] - 2026-10-09

### Fixed

- Removed local debug interface from release.

## [1.0.2] - 2026-10-09

### Fixed

- In menu bar mode, closing the window also leaves the Dock. Now only the menu bar icon stays active.
- Fix high CPU usage when in background. CPU usage is now 0% for most of the time.

### Changed

- Lighter System Data scans. Now limited to 3 CPU cores.
- Small UI and translation improvements.

## [1.0.1] - 2026-10-07

### Added

- Siri & Apple Intelligence: an (i) on the iCloud sync row while it is off, saying that if it is turned on, changes MacSpace makes
  to Siri also reach your other devices.
- Settings: the version of MacSpace, next to Check Now.

### Changed

- Settings: updates have a section of their own, and the macOS release is at the end of the page.
- The menu bar menu: Settings… on its own, then Open Panel (it was Open MacSpace) and Quit MacSpace.

### Fixed

- A click on the menu bar icon brings the MacSpace window in front of other apps, open or closed. It stayed behind the app in
  front.

### Removed

- Debloat's "Not tested" badge.

## [1.0.0] - 2026-10-07

The first public release. MacSpace is a System Data and Apple Intelligence cleaner for macOS 27 or later on Apple Silicon.

### Added

**System Data**

- Explains what fills System Data. The total is the figure System Settings shows, and the page breaks it down into caches, logs,
  diagnostic reports, system assets, app data, document version history and more. What MacSpace does not recognize appears as
  "Not identified" instead of being left out.
- Frees what is safe to delete from Free now: system caches, old diagnostic and crash reports, unused system assets, and the caches
  of Chromium and Electron apps while the app is closed.
- Deletes the document version history on request, after a confirmation that says it cannot be undone.
- Finds the leftover files of a macOS update that is already installed and deletes them on request.
- Explains each item that only macOS or another app can clean, and says what to do by hand (for example, which setting to change or
  which command to run).
- Measures the folders only an administrator can read through the privileged helper, and names any place it could not measure.

**Siri & Apple Intelligence**

- Switches Apple Intelligence off from its tile or its page, and back on.
- Deletes the Apple Intelligence models macOS keeps on disk once it is off, from a button or automatically in the background.
- Shows how much space the models take and whether a download is in progress.
- Tells you when another account on the Mac keeps Apple Intelligence on, or when a deleted account still holds the models.
- Warns before a change that would also change Siri on your iPhone and iPad through Siri's iCloud sync.
- Can check every 15 minutes, while MacSpace is open, that Apple Intelligence stays off, and notify you if macOS turns it back on.
- Says that there is nothing to switch off in a virtual machine.

**Other System Files**

- Shows the space outside System Data that macOS counts as purgeable, grouped by what holds it.
- Frees the files apps marked purgeable now, instead of when the disk is nearly full.
- Removes the copies of cloud files kept on the Mac and leaves the files in the cloud.
- Does not offer again what macOS declined to free, and lists it as "Left alone".

**Debloat**

- Switches that turn off analytics sent to Apple, personalized ads and the advertising identifier, Siri AI, Visual Intelligence,
  generative search indexing, Apple Intelligence features such as Writing Tools, Spotlight internet results, Game Center, Apple
  News, hang tracing, the crash report dialog, Siri and Dictation improvement, and dictation and translation on Apple servers.
- Controls that macOS enforces through a policy share one configuration profile, which you approve in System Settings.
- Disable all and Enable all buttons. Each switch can be turned on again, and MacSpace restores the settings it saved.
- Checks every 15 minutes that the features stay disabled, turns off again what macOS switched back on, and notifies you.
- Labels a control "Not tested" when it has not been verified yet.

**App**

- Onboarding on a new install: one screen for each missing permission (Full Disk Access, the privileged helper, notifications),
  then how much space MacSpace can free. Steps you already allowed are skipped.
- A dashboard of tiles, one for each module and one for the disk, that follow the Mac by themselves and show how much each module
  can free.
- A menu bar icon. A click opens MacSpace, and a right click lists each module with its status.
- Background mode: closing the window can quit MacSpace, keep it in the menu bar, or keep it running with no menu bar or Dock icon.
- Notifications when an automatic cleanup frees at least 100 MB, when a long action ends while MacSpace is not in front, and when
  the disk is almost full. Each can be switched off, and a click opens the page it is about.
- Automatic cleanup: every module that can free space does it every day, every 3 days or every week, with a page of recent cleanups
  and the total freed.
- Seven themes (Deep, Mono, Sketch, Nord, Aurora, Terra and Ink), each with a night and a day look. MacSpace follows the system
  appearance or stays night or day.
- A Liquid Glass window: each tile opens into its page, and Back goes up one level at a time.
- Five languages: English, Portuguese (Brazil), French, Spanish and German.
- A privileged helper for the few tasks that need an administrator. It answers only the signed app, you approve it in
  System Settings, and it installs only from the Applications folder.
- Automatic updates through Sparkle, with a Check for Updates command. Every update is checked against a signature before it installs.
- A Permissions page in Settings that shows Full Disk Access, the helper and the configuration profile, and what each one is for.
- A switch to open MacSpace at login.

[Unreleased]: https://github.com/1architect/macspace-releases/compare/v1.1.4...HEAD
[1.1.4]: https://github.com/1architect/macspace-releases/compare/v1.1.3...v1.1.4
[1.1.3]: https://github.com/1architect/macspace-releases/compare/v1.1.2...v1.1.3
[1.1.2]: https://github.com/1architect/macspace-releases/compare/v1.1.1...v1.1.2
[1.1.1]: https://github.com/1architect/macspace-releases/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/1architect/macspace-releases/compare/v1.0.3...v1.1.0
[1.0.3]: https://github.com/1architect/macspace-releases/compare/v1.0.2...v1.0.3
[1.0.2]: https://github.com/1architect/macspace-releases/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/1architect/macspace-releases/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/1architect/macspace-releases/releases/tag/v1.0.0
