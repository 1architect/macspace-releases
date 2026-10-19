# Plan: one Caches page, developer caches, uniform rows

Status: approved on 2026-10-12 and built on 2026-10-13, waiting for the maintainer's check before commit. Differences from the
plan: the confirmation reads "Free the selected caches?" (the size is on the button), and "Smaller items" of a block is one row.
Changed on 2026-10-13 at the maintainer's request: no exceptions (the boxes already say what is freed), the boxes animate, and
recommendations are bolder (an app cache untouched for 3 days, 7 when no app can be named for it; a developer cache untouched for 7
days; Homebrew's downloads always). The interface rules it follows are in
[CONTRIBUTING.md](../CONTRIBUTING.md#interface-rules), added with this plan.

## 1. What is wrong today (from the screenshots, 2026-10-12)

| Problem | Where |
|---|---|
| The same cache shows up three times | Firefox, Enscape, Homebrew, GeoServices and swiftpm are in the chart's Caches block, in Everything else › Caches, and in App caches |
| Homebrew shows up three times | "Homebrew" (2.57 GB of installed packages) in Everything else, the Homebrew cleanup row in Free now, and "App cache: Homebrew" in Caches |
| Several rows called "Smaller items" on one page | Caches block page: one per kind, all with the same title |
| Four different verbs | Free, Delete, "Free all", and rows with no button (Trash: Open; App caches: only inside the group) |
| Facts written as grey text | "Comes back as it is used", "App container", "App group data", "(MobileAsset)" and "(your Library)" inside titles |
| (i) repeating what the row says | App caches: the (i) says what the grey note already says |
| Lists in no clear order | App caches puts a 10 MB cache above a 306 MB one (sorted by "unused first", then by size) |
| The classification does almost nothing | The scoring only picks which boxes start checked, on a page the user rarely opens. Clean and automatic cleaning ignore it, so in practice it adds a grey note next to the item. Mole lists the same folders |

## 2. The new page

A single **Caches you can free** page replaces App caches, Everything else › Caches and the Homebrew cleanup row. The
chart's Caches block is split in two:

- **Caches you can free**: everything on the new page. Its block is part of "Can be freed", so the tile and the main Free
  button count it.
- **Other caches**: Apple's caches that macOS manages. They are listed once, there, with no button.

Page layout, top to bottom (each section sorted largest first, each with a select-all box in its header):

1. **Recommended.** Caches from every section that MacSpace is confident about. Each has a pill naming its section (App,
   Developer, Homebrew, Web) and a pill saying why ("Not opened for 45 days", "App not installed", "Old Xcode builds").
   Checked by default.
2. **Come back with use.** App caches in use. Pill: "Comes back with use". Caches of open apps are listed too, with an "Open
   now" pill and no box: they are freed after the app quits.
3. **Developer.** What section 3 below finds, minus what is already under Recommended.
4. **Exceptions.** Caches the user excluded. They are never checked and never freed by Free or automatic cleaning. Each row
   has a pill button to put it back.

Every cache row: box, title, pills, folder button, then an **×** pill button that moves it to Exceptions after a
confirmation ("Never free Firefox's cache?" / "MacSpace won't free it again. You can undo this under Exceptions." / "Add
exception"). No (i) unless there is something a pill can't say.

Bottom button:

- "Free recommended 1.2 GB" while the boxes match MacSpace's suggestion.
- "Free selected 640 MB" as soon as the user changes a box.
- The user's choice is saved. From then on, the System Data page's main Free button and automatic cleaning free the saved
  choice instead of the suggestion.
- Select-all is remembered per section: if the user checked "all" in "Come back with use", caches that show up later in that
  section are checked too, until they uncheck it.

## 3. Developer caches

Measured on this Mac today: Homebrew cleanup 181 MB, SwiftPM 64 MB, pip 16 MB, cargo registry 290 MB, `~/.cache` 1.8 GB (all
of it `codex-runtimes`, which is an app's runtime, not a cache: it must not be offered). On a working developer's Mac
DerivedData and simulators alone are often tens of GB.

| Source | How it is freed | Recommended when |
|---|---|---|
| Xcode DerivedData | delete per project folder | the project's folder no longer exists, or unchanged for 30 days |
| Xcode iOS/watchOS/macOS DeviceSupport | delete per OS version | not the newest version of each OS |
| Simulators | `xcrun simctl delete unavailable` | always (they cannot run) |
| CoreSimulator caches | delete | unchanged for 30 days |
| Homebrew | `brew cleanup` as today (old versions), then downloads as a second row | old versions: always |
| npm, Yarn, pnpm, bun | the tool's own clean command when installed, else the folder | unchanged for 30 days |
| pip, uv, SwiftPM, CocoaPods, Gradle, cargo registry, Go modules (`go clean -modcache`) | same | unchanged for 30 days |
| `~/.cache/<name>` | only names on a known list; unknown names are never listed | unchanged for 30 days |

Not touched: Xcode Archives (needed to read crash reports), simulator devices that still run, Docker, model files
(`~/.cache/huggingface`, `codex-runtimes`).

## 4. SDK and app changes (every module can use them)

- `Selection.sections`: named parts of a choosing page, each with a select-all box. The page draws a header per part.
- `Selection.remember`: the app sends each change to the module (`selectionChanged` with the ids and which sections are "all"),
  and the module saves it. The module is the only place that knows the saved choice, so its Free button and automatic cleaning
  can use it.
- `Selection.suggestedTitle` / `action.title`: "Free recommended" while the boxes match the suggestion, "Free selected" after.
- `Row.badges: [Badge]` (more than one pill per row) and `Row.accessory: Action?`: a small pill button after the folder button
  (× for "add exception", ↺ for "put back").
- A row with a box but `selectable: false` (open apps): drawn with the box dimmed and the reason in its pill.

Per module:

| Module | What changes |
|---|---|
| System Data | The new page, the two cache blocks, developer caches, the pills, one verb, sorting, no repeated rows |
| Other System Files | Grey notes become pills; rows sorted; "Free" everywhere. Its cloud folders can use exceptions later; not in this plan |
| Siri | Pills and sorting; no selection page |
| Debloat | "No longer offered" texts become a pill plus one short line; sorting by name (rows have no size) |

## 5. Questions for the maintainer

1. **Developer caches as its own module or inside System Data?** Recommended: inside System Data, as part of the Caches page.
   As a separate module with its own tile, every developer cache would appear twice (its tile and System Data's caches),
   which the new "one item, one place" rule forbids.
2. **Name of the page.** "Caches you can free" (pt-BR "Caches que podem ser liberados"). "Purgeable caches" would be confused
   with Other System Files' "Purgeable app files", which is macOS's own mechanism.
3. **Should Other System Files' "Purgeable app files" move into this page?** Recommended: no. It is one button with no list
   (macOS doesn't say which files), so it can't have boxes or exceptions.
4. **Approve the checkbox design** in the mockup sent with this plan.

## 6. Text review: texts added since 1.0.3

Each line: today's English → proposed English. Translations follow once approved. "Drop" means the text goes away because a
pill or the new layout says it.

**Debloat**
- "No longer offered: Apple deprecated its policies on macOS. To turn Apple Intelligence off, use the Siri & Apple Intelligence
  page. Switch this off to remove the policies." → pill "No longer works" + "Switch it off. To turn off Apple Intelligence, use
  the Siri page."
- "No longer offered: it stops Mail search from working. Switch this off, then restart your Mac." → pill "Breaks Mail search" +
  "Switch it off, then restart your Mac."
- "Siri AI no longer starts, and Spotlight goes back to classic search. Apple Intelligence and its other features stay on." →
  "Turns off Siri AI. Spotlight goes back to classic search. Other Apple Intelligence features stay on."
- "Screen Time or another profile already sets this. MacSpace cannot change it there." → drop (the pill "Set by another profile"
  says it).

**System Data, cleaning**
- "A program is still using these files. Try again later." → "An app is using these files. Try again later."
- "Couldn't check which files are in use, so nothing was deleted." → "Nothing was freed: MacSpace couldn't check which files are
  in use."
- "Couldn't check which programs are running, so nothing was deleted." → "Nothing was freed: MacSpace couldn't check which apps
  are open."

**Wallpaper downloads**
- "Aerial wallpapers and screen savers that macOS is downloading. A large figure means downloads that got stuck." → "Wallpapers
  and screen savers macOS is downloading. A large size means stuck downloads."
- "Delete stalled wallpaper downloads?" → "Free stuck wallpaper downloads?"
- "Deletes unfinished downloads (up to %@) that haven't changed in %lld days. Downloads still in progress stay, and macOS
  downloads again what it still needs." → "Frees up to %@ of downloads stuck for %lld days or more. macOS downloads again what it
  needs."

**Protected by macOS**
- "Caches and temporary files of macOS's services and of the other accounts on this Mac." → "Temporary files of macOS and of
  other users on this Mac."
- "Other accounts' and macOS services' temporary files" → "Temporary files of macOS and other users"
- "While Apple Intelligence is on, MacSpace leaves them alone: its models download and update through them." → drop (pill "Kept
  while Apple Intelligence is on").
- "Apple Intelligence's models and other assets that macOS keeps closed to every app: %@. They are in the same folder as System
  assets, which counts only the families it can open." → "Apple Intelligence models and other files no app can open: %@."
- "Databases of macOS's services that no app can open: %@." → "macOS databases no app can open: %@."
- "Other folders macOS keeps closed to every app: %@." → "Folders no app can open: %@."
- "The file system's own metadata for every file and folder, and what changed between this reading and System Settings'. No app
  can measure what is in these folders, so the block's size is what System Settings counts minus everything MacSpace lists." →
  "What the disk records about each file, plus changes since System Settings measured. This is System Settings' total minus
  everything listed."
- "Without the %lld families macOS keeps closed, among them Apple Intelligence's models: they are under Protected by macOS." →
  "%lld more, including Apple Intelligence models, are under Protected by macOS."

**App caches** (replaced by the new page)
- "Unchanged for %lld days", "Not opened for %lld days", "App not installed" → kept as pills.
- "This cache has not changed for %lld days." / "Its app was last opened %lld days ago." → drop (pills).
- "No installed app has its name; the app was removed, or is on a disk that is not connected." → drop (pill "App not installed").
- "MacSpace cannot tell which app or tool uses it, so it is not checked." → pill "Unknown app".
- "Comes back as it is used" → pill "Comes back with use".
- "In use: it wrote %@ in the last two days…" / "In use lately: …" → drop (pill).
- "Apps' caches in your Library. Checked: those unchanged for a month…" → drop (sections say it).
- "Delete the chosen caches?" → "Free %@?"
- "An app rebuilds its cache when it needs it again; its next launch may be slower." → "Apps rebuild their caches. They may open
  more slowly the first time."
- "Apps and macOS rebuild these caches as they run. Third-party ones can be freed from App caches, under Free now; Apple's are
  left to macOS." → "macOS rebuilds these by itself." (Other caches block only.)

**Homebrew** (moves to Developer)
- "Homebrew's own cleanup, as Terminal runs it, without uninstalling, updating or sending analytics." → "Runs Homebrew's own
  cleanup. Nothing is uninstalled or updated."
- "Run Homebrew's cleanup?" → "Free %@ from Homebrew?"
- "With every download too: %@; Homebrew downloads them again when it needs them." / "Free all" / "Also delete every Homebrew
  download?" → a second row "Homebrew downloads" with pill "Downloads again when needed"; "Free all" goes away.
- "Homebrew is running; try again when it is done." → "Homebrew is busy. Try again when it's done."
- "Homebrew's own cleanup is under Free now when it has something to free." → drop (Homebrew's packages are listed once).
- "Homebrew's usual cleanup stopped: %@" → "Homebrew's cleanup failed: %@"

**Trash**
- "Files you deleted, until the Trash is emptied in the Finder." → "Files you moved to the Trash."
- "The Finder deletes items that have been in it for 30 days." → pill "Empties after 30 days".

Fine as they are: "Loading…", "Show in Finder", "working…", "Open", "Set by another profile", "Kept while Apple Intelligence is
on", "Protected by macOS", "Models and system assets", "Other protected folders", "File system metadata", "Logs for all
users", "Running Homebrew's cleanup…", "Homebrew is not installed", "Old versions and downloads Homebrew no longer needs: %@.",
"Frees about %@: …".
