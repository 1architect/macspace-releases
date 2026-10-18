# Module refresh behavior

Implemented on `fixes-and-improvements-v111`, 2026-10-18. Module contract version 5.

## Loading and updating

- **First load:** use the existing loading pill, progress and page cascade. **Every subsequent read, including explicit Refresh and returning from All done:** preserve the current page, scroll position, groups and choices. Explicit Refresh still invalidates measurements first.
- Graphs pulse with the existing loading wave during every scan. Apply completed measurements only where values changed; do not replay the whole-page cascade. Home captions show loading text/progress immediately for every scan, regardless of duration. Cached/status-only reads remain silent.
- **Automatic scan:** retain the current page, group stack, choices and scroll-view identity. Report real progress in the existing widget/pill; page details remain visible and interactive. Forced automatic invalidation (such as profile approval checks) follows this rule too.
- **Status update:** refresh live operation counters from the last measurement without querying services or enumerating files. It produces no loading state.
- Cached reads report no scan progress. A newer read or action supersedes older progress immediately, so a late result cannot restore old data or leave the widget loading.
- Page cleanup uses the same live page as reload: keep existing details visible and interactive and pulse the graph while working; retain the All done completion. Row actions use only the inline text flag and its progress fill, without hiding the page. `ActionRequest.rowID` identifies the target UI row.
- A verified `ActionResult.presentation` updates the tile and page atomically without another scan. Modules retain unrelated cached measurements. Background row actions publish `Row.activity` using the same flag.
- Dock visibility alone controls the bottom fade reservation, so an expired notice or removed primary action leaves no extra bottom fade.
- Back dismisses All done to the module page before considering group or home navigation.
- Confirmations share a left-aligned icon, heading and message, including cache cleanup.

`ModuleHandle.isRefreshing` describes reported scan work. `isReloading` describes only the first load without an existing page. `ScreenView` uses only `isReloading` for the initial details cascade; page cleanup never hides existing details.

## What is followed

Each canvas registers its destination and uses the existing `WindowReader` to identify its window. Visible destinations are combined across windows:

- Home follows all dashboard tiles; automatic normal reads request tile progress without constructing unused module pages.
- An open module follows that module's tile and page. Opening it refreshes its page presentation even when its tile was just read on Home.
- Settings does not poll modules. Modules covered by another page are not polled unless another visible window shows their page or a dashboard.
- Minimized/closed windows and a hidden app do not contribute visible destinations. Closing the last canvas does not re-enable polling.
- Separately enabled watches and automatic cleanup continue without a visible module. Their completion refreshes the UI only when that module is watched. User actions still verify their results.

## Intervals and caches

Ordinary polling is 60 seconds after the preceding refresh finishes while MacSpace is active, or 600 seconds when another app is active with a MacSpace window still visible. Fast operation polling overrides either interval; its minimum is two seconds.

| Module | Measurement cache | Fast status/scan polling |
|---|---|---|
| System Data | 600 seconds | Every 2 seconds during cloud removal using shared live counters; otherwise none. A failed helper measurement can be retried after 60 seconds without repeating the full scan. |
| Other System Files | 60 seconds; cloud eligibility separately 600 seconds | Every 2 seconds during cloud removal, using the status-only path. Periodic UI polls retain measured data even past its TTL while removals run. Completion remeasures only the affected provider, then reconciles its cached row in both modules. No whole-module measurement is requested. Explicit Refresh can still force a measurement during removal. |
| Siri & Apple Intelligence | 4 seconds | Every 5 seconds only while models are downloading, releasing, purging, automatically releasing, or an asset purge is being retried. AI being enabled alone uses the ordinary interval. |
| Debloat | 15 seconds | None. App activation forces a quiet invalidating read when this module is visible, so profile approvals are recognized without folding the page. |

When a window becomes visible again, watched modules whose last UI refresh is at least two seconds old are read again. App activation otherwise catches up visible modules whose last UI refresh is at least 60 seconds old. The ordinary age refers to the last host refresh; each module independently owns the age of its measured snapshot.

The optional Siri watch runs every 900 seconds and is disabled by default. The Debloat watch also runs every 900 seconds and is enabled by default. Their schedules are independent of presentation polling. System Data, Other System Files and Siri participate in separately configured automatic cleanup.

## Module contract version 5

- `tile(context:progress:)` reads the dashboard presentation and reports real scan progress. All four shipped modules implement it and share the scan with concurrent page requests.
- `screen(context:progress:)` reads a page and reports scan progress. Cached presentations stay quiet.
- `status(context:)` optionally returns a lightweight `(tile, screen)` presentation based on already measured data and current counters. It must not enumerate files or query services. Returning nil asks for an ordinary read. The host checks this entry point on automatic reads and bypasses it for explicit invalidation.
- `Tile.refreshAfter` requests the next automatic update sooner. Other System Files and System Data implement `status` for shared background cloud removal. Other modules currently return nil and use their ordinary measurement/cache path.
- System Data remeasures only action targets, including remaining files after partial cleanup; Other System Files reconciles its affected service or backup target; Siri asset purges remeasure only assets/model sizes. Their action results return a verified cached presentation. System Data adjusts its displayed baseline by the same counted target delta as its graph, retaining the full scan age. That reconciled baseline remains an estimate until the next complete category measurement.
- Cloud completion keeps eligible downloadable bytes separate from total local bytes (pinned files may remain). Both modules use `CloudFileRows` and `CloudDownloadRemovals`; unknown/unreadable measurements retain the previous value. Volume free-space gains are history data, never item sizes.
- `invalidate()` drops measured data; it does not publish UI by itself. `ActionResult.refresh` requests a presentation refresh after an action.
- The host owns visibility, timers and whether loading is explicit or automatic. Modules supply measurements, counters and their progress; row actions reuse the existing capsule, hover and progress treatments.

The SDK and all four bundled manifests are version 5. A version-4 module is rejected by the existing compatibility check instead of being loaded against the changed protocol.

## Legend animation

The legend grid no longer animates its layout when measured segments change. Its inherited grid-layout animation is cleared; each element retains `PageItemReveal` for the existing vertical cascade, and each byte label retains the vertical roll/blur style with an anchored overlay that keeps outgoing glyphs out of layout. Fade-only content changes are reserved for Reduce Motion. Graph loading is independent of legend visibility, so live reads retain the legend. Page navigation transitions remain unchanged.

## Text motion

`ChangingText` draws rolling word/digit runs through `VerticalRollRenderer`. Only changed runs receive the existing vertical
travel, blur and stagger; its drawing transform has zero horizontal travel at every frame. Unchanged runs are drawn once at their
resting layout positions. Native numeric content transitions are not used because their internal glyph-position interpolation
cannot be restricted to the vertical axis. The current text alone measures the label, using tabular digits, and outgoing runs
remain drawing overlays. Text still owns shaping, kerning, wrapping and truncation. All done uses the same renderer in a fixed-width
centered counter. Interrupted rolls cancel pending completion work before starting the next update.

Dock and badge container animations track presence/count changes, rather than the entire action phase or badge contents. Working
and hover color animations are scoped to the background so they cannot animate the text line's frame when a label changes.

Row and page action pills share `PillMorph` for resizing: the shell interpolates its footprint using `Theme.layout`, while its label
is placed at its destination size against the leading edge. Glyphs retain `ChangingText` vertical roll/blur independently of shell
geometry. The same action identity survives idle, progress and result. Progress fills carry the fraction without duplicate percentage
text; cloud flags retain the removed-byte count. Inserted/removed rows and flags use `PageCascade` vertical arrival/departure with
staggered timing. Changed values reuse the same page order for their roll/blur delay; unchanged rows are never replayed. Action labels
begin their roll immediately with the shell resize.

`Tests/App/TextRollTests.swift` covers unchanged labels/units across digit growth, changed-word/digit matching, Unicode preservation,
zero horizontal travel through spring overshoot, blur/vertical endpoints and Reduce Motion.
`results/vertical-text-20261018/app-tests.txt`: 111 AppTests, 109 passed and two optional render snapshots skipped.

## Window controls and confirmations

Inactive controls use the same fallback as Reduce Transparency, with day/night colors and a fading transition. Active glass also
uses the selected day/night appearance. Last-window closure hides the active app first and defers accessory-policy demotion until
activation has passed to another app. Status/popover windows cannot promote the app back to regular presence. This addresses a
suspected cause of the reported menu-bar flicker; the visible result requires user verification.

All `AppAlert` layout passes align the actual icon and text frames to the native 20-point leading inset, in addition to setting left
text alignment. This includes short cache confirmations whose native field frames are centered.

## Verification and references

`results/live-cleanup-ui-20261018/verified-all-tests.txt`: 470 tests, 466 passed and four optional tests skipped (two live CacheDelete
opt-ins and two saved render snapshots). The follow-up `results/rolling-text-20261018/app-tests.txt` verifies the restored immediate
loading behavior (106 AppTests, two optional skips). `localization-check.txt` records compiler extraction and all eight UI languages. Regression
coverage includes live/manual refresh, immediate loading captions, retained choices, stale reads, targeted partial cleanup,
excluded clones, repeated purges, shared cloud progress, JSON round trips, All done verification, inline permission failures,
confirmation frames and window presence. Visual verification of transitions, OneDrive flags/fades, inactive day/night controls and
the menu bar on close is performed by the user; no GUI automation is used.

`results/pill-morph-20261018/final-tests.txt`: 261 App, Other System Files and System Data tests, 259 passed and two optional render
snapshots skipped. Offscreen layout tests verify shell interpolation with a fixed leading label origin and natural label size;
page cleanup retains its presentation until verified values arrive. `localize.txt` records compiler extraction in all eight languages.

Main sources: `App/Registry/ModuleHandle.swift`, `App/Registry/ModuleHost.swift`, `App/Shell/MainView.swift`, `App/Renderer/ScreenView.swift`, `Sdk/Contract/Module.swift`, `Sdk/Interface/Tile.swift`, and each module's snapshot store/screen builder.
