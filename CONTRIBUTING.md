# Contributing to MacSpace

Thank you for helping with MacSpace. This page says how to build and test it, what a good pull request contains, and which rules
keep the app safe. Everyone who takes part follows the [Code of Conduct](CODE_OF_CONDUCT.md).

MacSpace is released under the [MIT License](LICENSE). By sending a contribution, you agree that it is released under the same
license.

## Before you start

- Read [Docs/Handoff.md](Docs/Handoff.md). It covers the repository layout, how the app and its modules fit together, how the
  privileged helper works, what is verified and what is not, and the open work.
- Findings about macOS itself are in [Docs/Research.md](Docs/Research.md). Add a finding there, with an evidence label, when your
  change depends on how macOS behaves.
- Maintainers: [Docs/Releasing.md](Docs/Releasing.md) describes how a version is released.
- For a large change, open an issue first so we can agree on the approach before you write the code.
- To report a bug, a missing feature or a wrong translation, use the issue forms on GitHub.
- To report a security problem, follow [SECURITY.md](SECURITY.md). Never open a public issue for it.

## Requirements

- A Mac with Apple Silicon running macOS 27 or later.
- Xcode 27 (the beta is fine). The command-line tools alone are not enough: they lack the SwiftUI macros the app uses.
- A Developer ID or Apple Development certificate is optional. Without one, the build is signed ad hoc and is not notarized. An ad
  hoc signature changes with every build, so macOS asks you for Full Disk Access again each time.

MacSpace is a Swift package. There is no Xcode project.

## Build and test

Point the tools at the Xcode 27 toolchain in every new shell:

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
```

If your Xcode 27 has another name, use its path instead.

Run the tests:

```bash
swift test
```

Build the app and install it in `/Applications`:

```bash
INSTALL=1 Scripts/Assemble.sh
```

`Scripts/Assemble.sh` builds `Build/MacSpace.app` and signs it. `INSTALL=1` also quits a running copy and copies the app to
`/Applications`. It asks for an administrator password if that folder is not writable. The header of the script lists every setting
(`CONFIG`, `VERSION`, `BUILD`, `SIGN_IDENTITY`, `OUT_DIR` and more). To force an ad hoc signature, use `SIGN_IDENTITY=-`.

**Run the app from `/Applications`.** The privileged helper registers only from an Applications folder. A copy that runs from
anywhere else cannot install it.

A build without `SPARKLE_PUBLIC_KEY` never checks for updates. The signing identity, the notarization profile and the update keys
belong to the maintainer and are not in this repository. You do not need them to build, run or test MacSpace.

`Scripts/SelfTest.sh` checks the installed app on your own Mac. It switches Debloat settings off and puts them back, and it writes
its report to `results/`, which Git ignores. Read it before you run it. It is optional.

GitHub Actions builds the package, runs the tests and checks the translations on every pull request. A pull request needs a green
run.

## Localization

MacSpace speaks eight languages: English, Portuguese (Brazil), French, Spanish, German, Simplified Chinese, Japanese and Korean. **Every text that appears on screen
needs a translation in all seven other languages.** The check below fails without them.

Translations live in `Localization/<Table>.json`. `App.json` holds the app's texts, and there is one table for each module
(`SystemData.json`, `Siri.json`, `OtherSystemFiles.json`, `Debloat.json`). Each entry maps the English text, exactly as the code has
it, to its translations in this order: Portuguese (Brazil), French, Spanish, German, Simplified Chinese (zh-Hans), Japanese (ja), Korean (ko).

```json
"Recent cleanups": ["Limpezas recentes", "Nettoyages récents", "Limpiezas recientes", "Letzte Bereinigungen", "最近清理", "最近のクリーンアップ", "최근 정리"]
```

After you change any text, run both commands from the repository root:

```bash
swift Scripts/Localize.swift
swift Scripts/Localize.swift --check
```

What they do:

- `swift Scripts/Localize.swift` reads every table and writes `<language>.lproj/Localizable.strings` into `App/Resources` (for
  `App.json`) and into `Modules/<Module>/Bundle` (for a module's table). `Scripts/Assemble.sh` copies these files into the app. The
  generated files are committed, so commit them with your change and never edit them by hand. The script stops if a translation
  drops a placeholder (`%@`, `%lld`, `%%`) from the English text, or if an entry does not have exactly seven translations.
- `--check` does the same and then builds the whole package with the compiler's string extraction, in a temporary folder, so it
  takes a while. It lists every text the code shows that no table has, and it exits with an error when any is missing. It skips the
  developer tools, the command-line tool and the helper, which stay in English. A format with no words to translate (`%@ · %@`)
  needs no entry.

How a text reaches the screen:

- In the app, SwiftUI literals are localized by themselves. Other text goes through `String(localized:)`.
- In a module, text goes through the module's own `loc(...)` (`Support/Localization.swift`), which reads the module's bundle.
- The names in Debloat's catalog, which the helper shares, go through `locKey`.

Write texts by the [interface rules](#interface-rules). If you are not sure of a translation, say so in the pull request and a native
speaker can review it. The translation issue form is the way to report a wrong text without changing code.

## Adding a module

Each module is a separate bundle that describes its screens for the app to draw. The steps are in
[Docs/Handoff.md](Docs/Handoff.md#adding-a-module). In short:

1. Create `Modules/<Name>/{Module,Bundle}`, and `Privileged/` if the module needs root.
2. Subclass `MacSpaceModuleEntry`, return a `MacSpaceModule` from `makeModule()`, and set the class as the bundle's
   `NSPrincipalClass`.
3. Write `Manifest.json` and `Bundle/Info.plist`.
4. Add the targets to `Package.swift`. The dynamic library product must have exactly the name of the folder.
5. Add `Localization/<Name>.json` and run the localization commands above.
6. Write tests in `Tests/<Name>`. Build the screens with pure functions of a snapshot, so the tests need no special Mac.

## Conventions

- Folder names start with a capital letter.
- Do not change a bundle identifier (`com.macspace.*`). Full Disk Access, the helper approval and update signatures depend on them.
- Anything new that uses a private Apple interface needs a guard that checks it on the running macOS build, and crash isolation.
  CacheDelete is the model: it runs in `MacSpaceCli` as a child process, so a crash there never takes the app down.
- Changes that need administrator rights go through the privileged helper, as a named operation in the module's `Privileged/`
  library. The helper answers only the signed app.
- `Sdk` and `Platform` are separate packages on purpose. Do not merge them into the main package (the reason is in the Handoff).
- Every switch shows the feature: on means the feature runs, off means MacSpace switched it off.
- Give a row a description only when its title is not enough. Keep it to one or two short sentences.
- Follow the interface rules below. A pull request that breaks one needs a comment in the code saying why.

## Interface rules

These apply to the app and to every module.

**Texts** (titles, notes, pills, descriptions, confirmations, footnotes):

- As short as they can be. One sentence when one is enough.
- Written for someone who is not technical. Name things the way the user sees them (the app, the Finder, System Settings),
  not the way macOS does inside (daemons, services, containers, purge, urgency), unless there is no other name.
- No telltale AI language: no "seamlessly", "simply", "just", "ensure", "robust", "leverage"; no em dashes; no "Note that";
  no exclamation marks; no lists of three for rhythm; no sentence that repeats the title.
- Say what happens and what it costs the user. Not how MacSpace works inside.

**One item, one place.** An item (a folder, a cache, an app's files) is listed on one page only: the page where the user can
act on it. Two ways to reach the same page are fine (a chart block and a row); two pages that list the same item are not. An
exception must be agreed with the maintainer and explained in a comment where the row is built.

**Order.** Lists are sorted by size, largest first. Rows without a size are sorted alphabetically. Any other order (steps, a
fixed sequence) needs a comment saying why.

**Facts are pills.** A short fact about a row (its state, why it is checked, what kind of item it is) is a pill (`Row.badge`),
not grey text after the title. The (i) is only for what a pill cannot say. Never draw an (i) that repeats the pill. After the
title, always in this order: the (i), the folder, the pills, then the row's button; the app draws them so (`RowView`).
Every pill says whether it asks something of the user (`Badge.Kind`): `.action` (restart, approve, switch it off elsewhere; its
help says what) is drawn orange, `.info` (a state, a kind, a warning such as "Cannot be undone") is grey. Orange always means
there is something to do: the same for banners (`warning` or a button to press), row flags (orange only for a result that asks
something: a failure or a restart; while they work and with any other result they keep their resting grey) and every other element. The page's main
button is the one exception: it is the page's action.

**Restart.** An item only a restart completes carries the app's one pill, `Badge.restartRequired(help:)`, never a pill in the
module's own words, and the page's main action is `Action.restart(title:)`, which the app runs (macOS's Restart dialog) without
calling the module. An action whose result has `restartRequired` ends on the main button as "Restart to finish", which opens the
same dialog.

**Freeing in the background.** Space MacSpace frees by itself while the row stays (macOS asked again, models deleted as soon as
macOS lets go) carries the app's one pill, `Badge.freeingInBackground(help:)`, in a row's or a switch's pills: never a pill in the
module's own words, and never `Row.activity`, which is for background work with a figure of its own. The app hides the row's button
meanwhile, and a Free that hands its work to it continues in the row instead of saying All done.

**System Settings and notifications are the app's.** A button that opens a pane of System Settings is
`Action.openSettings(title:url:)` (Full Disk Access: `Action.allowFullDiskAccess(title:)`), which the app opens at once without
calling the module (its button never says Working), and only for `x-apple.systempreferences:` URLs. A pane the module opens by itself, with no button (a profile staged for
approval), goes through `context.services.openSettings`. A notification is `context.services.notify(title:body:)`: the app posts it
with the module's id, so a click opens the module's page. The module keeps the option switch that decides whether it notifies
(`notify`). No module imports UserNotifications or opens System Settings with `NSWorkspace`.

**Buttons in rows are flags.** Every button in a row, in Settings and on every module's page, is the row action flag: text on
a faint capsule, the look of the (i) and folder pills, darker under the pointer (`RowFlagStyle`; a module row's Free is the same
flag, with its progress and result). No system buttons and no other pill style in rows. Where it goes: when the row shows a figure or a
switch on its right (a size, a version), the flag stands right after the title, its (i), its folder and its pills, and the figure keeps the right edge;
when the row has no figure, the flag takes the right edge (`RowFlagPlacement`). Modules set `Row.trailing` and `Row.actions`; the
app places them.

**One title style.** Every list and section title (Settings and every module page) is drawn the way macOS's System Settings
draws its grouped lists: semibold, in the text's color. A title names its group in a few words ("Models", "Free now"), never a
sentence, a count or a state. Modules set `title` on the list or section; the app draws it.

**The (i) is a static description.** It says what the item is and what acting on it does, the same in every state: no sizes,
counts, dates, file lists or current state. Those are the row's figure, its subtitle and its pills; what a state means right now
goes in the pill's hover tag (`Badge.help`). Five lines at most in the balloon, three ideally (`InfoText` in the SDK, which the app
enforces). Steps to follow stay in `steps`. Each module's tests check their pages with `InfoText.violations(in:)`.
Never a list: no bullets, dashes or numbering, in the text or in `steps`; the app draws steps as sentences, not numbered.

**Rows come and go the same everywhere.** A row or section added or removed, on a module's page or in Settings, arrives and
leaves with the page's cascade (`PageCascade`, `rowCascade()` in Settings), in an animated change. Settings is not a module
page, so a new Settings row needs it explicitly. Settings' pages are a `PageForm` of `PageSection`s, never a system `Form`: a
form fades the switches and menus of a row on its own and leaves them in place while the row slides, and it builds every row of
a long list at once.

**One verb.** Every action that frees space is titled Free, on buttons and in confirmations ("Free", "Free 120 MB", "Free
selected"). Not Delete, Clean, Remove or "Free all". An action that cannot be undone keeps the "Cannot be undone" pill.

**Freeing looks the same everywhere.** The page action morphs into the existing progress pill and All done page. Individual row
buttons are text flags with the folder flag's hover behavior; they morph into an inline cleaning flag with the same progress fill.
A row action never hides the page or opens All done. Background work uses `Row.activity` on the same flag. Preserve its action while
it runs. Animate flag insertion/removal with the existing vertical cascade. Numeric changes within a phrase use the original native
numeric-text transition. A different phrase gets a new drawing identity and the existing vertical roll/blur; do not interpolate
unrelated words through the numeric transition. Reduce Motion uses opacity. The current label alone measures layout; animated
text stays anchored in an overlay. Inherit the caller's font and digit spacing; tabular digits belong only to explicit counters or
aligned values. Do not animate the whole text line's layout. All done retains its original per-piece roll and blur.
Idle row flags fit their title. While working, a flag fits the widest message it has shown so far: it grows for a longer one and
never narrows until the work ends, then fits its result and, after that, its idle title. It does not reserve labels it has not
shown: reserving "Freeing in the background" left "Freeing space" in a pill with an empty tail (2026-10-18). Numeric variants of
one phrase share a width (`Action.labelSamples`).
Use the existing anchored shell morph only at these phase boundaries; progress updates must not move adjacent controls. Longer unexpected messages truncate, with
full text in help. The orange page button is always one line and 31 points high: cap its width to the page and truncate rather than
wrap. Its shell may resize horizontally; measure the destination label independently of the shell's intermediate width.
Background continuation occupies the same action flag using `Row.activity`; keep its action id and parameters. Do not add a
second badge or successful completion flag for the same work. Matching background activity suppresses All done while preserving
verified savings, history and failures. When no page action remains, the bottom button fades in place in a fixed-height dock;
release footer space only after its departure completes, and scope footer layout animation to the scroll area.
A progress fill replaces percentage text in action pills. No middle dots or ellipses in loading/cleaning labels.

**Targeted cleanup results.** Verify affected targets and reconcile their cached measurements, then return `ActionResult.presentation`
with the updated tile and screen. Retain unrelated measurements. Do not deduct a volume free-space delta from an item's size:
concurrent writes and APFS sharing make those different quantities. A full scan can run later automatically or through Refresh.

**Confirmations are short.** The title asks ("Free 250 MB?"). A message is one line about what the user would not expect, such as
apps that quit. The app icon, heading and message must share a left-aligned leading edge, including cache confirmations.

**Loading.** Only the first load has no rows and uses the existing cascade. Subsequent reads retain the current page, scroll and
selection, including manual Refresh, page-wide cleanup and returning from All done. Cleanup uses the same live page as reload;
keep details visible and interactive while its progress runs. Graphs use the current loading wave during every scan. Apply only
changed measurements when it finishes. Home captions show loading and reported progress immediately, regardless of scan duration.
Graph animations also start immediately. Modules report real scan
progress through `tile(context:progress:)` and `screen(context:progress:)`, sharing scans with `LoadProgressRelay`.

**Charts.** Blocks stand in columns across the chart, each column's blocks stacked down it. On a tile, only the chart's outer
corners follow the tile's (its radius less the margin); the corners between blocks keep the blocks' own.
- When a row stands for files the user can open, list them in `Row.paths` (a folder button shows them in the Finder). When a page
  has a hero chart, give each block the rows it is made of in `UsageSegment.items` (a click opens a page of them), and leave them
  out on the tile. The doc comments in `Sdk/Interface/Widgets.swift` say how.
- Commit titles start with a capital letter and say what changed. Naming the area first is fine ("Debloat: ...").
- Do not commit signing material, keys, tokens or experiment results. The `.gitignore` covers the usual files.

## Pull requests

Keep each pull request to one change. Before you open it:

1. `swift test` passes.
2. `swift Scripts/Localize.swift --check` is clean, and the generated `.strings` files are in your commit.
3. New or changed on-screen text has a translation in all eight UI languages.
4. UI changes include screenshots, in the night and the day look when both are affected.
5. [CHANGELOG.md](CHANGELOG.md) has an entry under "Unreleased", in the right group (Added, Changed, Deprecated, Removed, Fixed
   or Security), written for people who use the app.
6. [Docs/Handoff.md](Docs/Handoff.md) is updated if you changed how the app is built, tested or put together.
7. The pull request says how you tested the change, and on which macOS build.

The pull request template has the same list.

## Documentation in eight languages

`README`, `PRIVACY`, `SECURITY` and `LICENSE` each exist in eight languages: the English file (`README.md`) in the repository root, and the other seven in `Docs/Translations/<language>/` (`pt-BR`, `fr`, `es`, `de`, `zh-Hans`, `ja`, `ko`), with the same file name. If you change one of them, update all eight. If you cannot, change the English file and
say in the pull request which translations are out of date, so a maintainer or another contributor can bring them up to date.

`CHANGELOG.md`, `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, `NOTICE` and the files in `Docs/` are in English only. Release notes are
written in eight languages, in `ReleaseNotes/<version>/` (`en.md`, `pt-BR.md`, `fr.md`, `es.md`, `de.md`, `zh-Hans.md`, `ja.md` and `ko.md`).

## Contact

Write to [dev@giomantovani.com.br](mailto:dev@giomantovani.com.br) for anything that does not fit an issue. For security problems,
use [SECURITY.md](SECURITY.md).
