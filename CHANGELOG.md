# Changelog

All notable changes to MacSpace are recorded in this file.

The format follows [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/). MacSpace follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- System Data: **App caches**, under Free now, lists the folders in `~/Library/Caches`, judged by the files' own dates and their app's last launch, with no list of apps. Those unchanged for a month whose app has not been opened for as long, or is not installed, are checked; the others are unchecked, and those in use say that they come back and how much they wrote in the last two days. Not listed: Apple's, caches of apps that are open, and folders with media or documents named by people. Its own button, never Clean or automatic cleaning.
- System Data: a **Homebrew** row runs Homebrew's own `brew cleanup`, with what it frees by Homebrew's dry run, and a second button that also deletes every download. Homebrew runs as you, without autoremove, auto-update or analytics.
- System Data: a **Trash** row opens the Trash in the Finder and says whether the Finder empties items after 30 days by itself.
- A group's page can let the user choose rows and act on the chosen ones (`Row.selection`): checkboxes, and the page's button titled with the chosen rows' total.
- System Data: the block of what no folder accounts for is **Protected by macOS** once everything MacSpace can measure is measured, and opens a page naming the folders macOS keeps closed to every app (Apple Intelligence's models, system databases) and the file system's own metadata.
- System Data: wallpaper and screen saver downloads that macOS left unfinished can be deleted from Free now, with the helper. Only the `CFNetworkDownload_*.tmp` files of idleassetsd that have not changed in 3 days go, so a download still in progress stays. Clean and automatic cleaning leave them out.
- A folder button beside a row's (i) shows its files in the Finder, selected in one window. Modules list a row's files with `Row.paths`; System Data and Other System Files do.
- System Data: a click on a block of the page's chart opens a page of the items it is made of, with the same page change and Back as a group. Modules list a block's items with `UsageSegment.items`.
- Other System Files: a click on a block of the page's chart opens a page of what it is made of: the purgeable app files with their Free button, each cloud folder's downloads with Remove Downloads and Show in Finder, and the macOS update waiting to install. A service MacSpace has nothing more to say about opens nothing.

### Changed

- Loading: a tile or a page also darkens its background and lets it lift again, over and over, while its module reads the Mac. A page with no chart (Debloat, Siri & Apple Intelligence) shows the shape of its groups and rows meanwhile, instead of a few grey boxes.
- Tiles: text is never shrunk to fit. Where a title and its figure do not fit on one line, the title (which may take two lines) is followed by the figure on a line of its own (`Tile.figure`). The status line under a title is that title's size, in regular weight.
- Charts: all blocks of a chart have the same corners, the smallest block's.
- Debloat: the Siri AI switch says what stays on: Apple Intelligence and its other features.
- A tile says what its module is cleaning, and how far it is, in place of its status line while the cleanup runs.
- While a page reads the Mac again, only its chart pulses: the legend and the rows fold away and come back with the new figures, and the main button says Loading.
- The main button keeps a warning on one line wherever the page has room.
- Tiles: the status line is regular weight, keeps one weight at any tile size, and lines up with the other tiles' (12 points from the bottom, as the charts are from the top). The text stays sharp, and the chart's blocks keep their places, while a tile lifts under the pointer or moves to another cell. No pointing hand over tiles and charts.
- Debloat: the tile's dots are shared out evenly over their rows, and stay solid while they pulse.
- The (i) and folder buttons are small capsules side by side, before the badge.
- The close and refresh buttons keep their look when the window is not active.
- System Data: the Caches group under Everything else says, behind its (i), why MacSpace leaves app caches alone.

### Removed

- Debloat: the Generative search indexing switch. It stopped Mail search from working, with or without Apple Intelligence ([#6](https://github.com/1architect/macspace-releases/issues/6)). If you had switched it off, MacSpace switches Generative search indexing back on by itself (with the helper); restart your Mac to finish.
- Debloat: the Apple Intelligence features switch. Apple deprecated its policies on macOS and their effect could not be verified; the Apple Intelligence switch on the Siri & Apple Intelligence page turns these features off. On a Mac where it is still on, it stays listed until you switch it off, which removes its policies.

### Fixed

- System Data: files reached by several hard links were counted once per path (1.49 GB too much for Spotlight's own store alone), and Apple's container caches that macOS counts as purgeable were counted in full; the listed items then added up to more than System Settings' figure, and hid that much of what no folder accounts for.
- System Data: Apple's containers under 100 MB were left out of System Data with the third-party ones (0.73 GB on the development Mac), and the parts of `~/Library/Logs`, `~/Library/Messages`, `~/Library/Photos` and `/Library/Logs` beside crash reports and Messages' attachments were measured by nothing. Both went to the block of what no folder accounts for.
- System Data: a file deleted while a process holds it open made the check for open files answer "unknown", so Clean deleted nothing.
- System Data: a cache is renamed, then deleted, so an app that starts meanwhile never finds half of one.
- Debloat: a policy that Screen Time or another profile sets is no longer shown as switched off (or partly switched off) by MacSpace. Its row says "Set by another profile", its switch cannot be flipped, and Disable all leaves it out. MacSpace no longer tries to undo settings that are not its own.
- Apple Intelligence downloads are no longer cut short by MacSpace: while Apple Intelligence is on, MacSpace never asks macOS to delete system assets, through which its models download and update. Clean, automatic cleaning and the background retries leave them out, and System Data lists them as kept. Switching Apple Intelligence off on the Siri & Apple Intelligence page still releases its models.
- Debloat: where the retired Apple Intelligence features switch is still applied, MacSpace removes its policies by itself (with the helper). They made macOS treat Apple Intelligence as restricted: System Settings hid it, said extensions were disabled by the organization, and its download stood still.
- System Data: the caches and temporary files of root, macOS's services and other accounts are measured (with the helper). Wallpaper and screen saver downloads that macOS left unfinished, which can grow to hundreds of GB, get a row of their own.
- System Data: a small item that is partly closed to MacSpace is no longer dropped before the helper measures it.
- System Data: a cache is no longer deleted while a command-line tool that owns it (such as the clang compiler), a helper of its app, or any other program is still using it. Clean and automatic cleaning check this again just before each deletion, and skip the cache when they can't tell.

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

[Unreleased]: https://github.com/1architect/macspace-releases/compare/v1.0.3...HEAD
[1.0.3]: https://github.com/1architect/macspace-releases/compare/v1.0.2...v1.0.3
[1.0.2]: https://github.com/1architect/macspace-releases/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/1architect/macspace-releases/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/1architect/macspace-releases/releases/tag/v1.0.0
