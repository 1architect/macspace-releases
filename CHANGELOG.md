# Changelog

All notable changes to MacSpace are recorded in this file.

The format follows [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/). MacSpace follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- Made the glass window easier to move with a persistent top drag handle, and easier to resize from every edge and corner.

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
