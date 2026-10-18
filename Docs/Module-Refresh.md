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
- The dock renders the current phase directly in a stable container; it never mirrors a loading/action phase in view state. Dock lifetime controls only the bottom fade reservation: hold it until the outgoing button's removal transaction finishes, then release it. A new visibility generation cancels a stale departure completion.
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

## Text motion and action labels

`ChangingText` routes numeric-only changes in an unchanged phrase through the native `.numericText()` transition with
`Theme.value`. Phrase changes use `TextMotionState` and the shared word renderer in `App/Shell/WordMotion.swift`, for captions,
row flags, page buttons and All done. The native numeric view is removed immediately at that boundary, so its unfinished 30% ->
60% transition cannot keep painting over “IA desativada.” A word playback has one generation; replacement cancels its task, and a
stale completion cannot clear a newer phrase. Counter updates during an entrance update its latest incoming snapshot without
restarting the word cascade.

Outgoing/incoming snapshots retain their fonts and measured bounds and share the caller's leading, center or trailing anchor.
Changed words alone use the original roll/blur treatment (0.45-second spring, 0.22-second exit, 0.025-second stagger). Unchanged
words draw once in the incoming paragraph. Native shaping and wrapping remain in one Text paragraph, with word attributes rather
than independently measured word HStacks. No horizontal motion, whole-line slide or fade-only replacement is added. Reduce Motion
uses the existing opacity fallback. A final renderer clip keeps glyphs/blur within each snapshot's trailing edge while retaining
vertical travel. Numeric views are recreated from the latest text after word playback, with no older phrase retained underneath.

Loading percentages keep their natural width and tabular digits, normal word spacing and the caption's right inset. Digit-count
changes take their natural width. Other figures retain proportional spacing. All done alone reserves width from its explicit
counting template. Single-line split fields use leading paragraph alignment to preserve trailing spaces; current text alone
measures layout. Word layers are overlays and cannot change pill height, reserved row widths, footer space or button truncation.
Changed text keeps the page cascade delay.

Idle row flags fit their title. `ReservedPillLabel` reserves known numeric variants of the current phase; unrelated future phrases
such as background cleanup do not widen “Freeing space.” `PillMorph` handles phase-boundary shell resizing with the existing page
button behavior. Optional `Action.labelSamples` supplies numeric variants; it decodes as nil for older saved actions and does not
change the module protocol version. Full messages remain available in help.

The orange page button keeps horizontal `PillMorph` resizing but is always 31 points high and one line. `SingleLineActionLabel`
measures its ideal width independently of the shell's intermediate proposal and caps it to the dock's available width. Long notices
truncate with full help text. No wrapping fallback is allowed. The original label measurements inherited a narrow intermediate
proposal during shell resizing, which could make even “Carregando” wrap; the separate ideal measurement prevents that feedback.

Progress fills carry the fraction without duplicate percentage text; cloud flags retain the removed-byte count. Inserted/removed
rows and flags keep the vertical cascade, while unchanged rows remain in place. A row flag's phase change also animates its containing
controls HStack with `Theme.layout`, so info/folder controls follow the resizing capsule instead of jumping. Fraction-only ticks do
not restart that layout animation; Reduce Motion disables it.

Other System Files retains the `purgeFiles` row action during retries, with “Freeing in the background” in `Row.activity` rather than
a separate badge. The same flag owns foreground progress and background work. A successful result whose verified presentation
contains matching row activity (action id and exact target parameters) does not create a second completion flag or All done page.
Failures, restart requests and unrelated background targets still keep their result UI. Savings/history are recorded as before.
The orange dock fades out with an opacity transition in a stable 31-point frame. `ActionDockLifetime` retains footer space until
SwiftUI's `.removed` animation completion, without a timer; a newer phase invalidates the old completion. Footer animation belongs
to the scroll area and cannot reposition the exiting dock.

## Window controls and confirmations

Inactive controls use the same fallback as Reduce Transparency, with day/night colors and a fading transition. Active glass also
uses the selected day/night appearance. Last-window closure hides the active app first and defers accessory-policy demotion until
activation has passed to another app. Status/popover windows cannot promote the app back to regular presence. This addresses a
suspected cause of the reported menu-bar flicker; the visible result requires user verification.

Every app-owned dialog must use `AppAlert`, including module/cache cleanup, startup, About, uninstall and error dialogs. Its modal
entry explicitly installs the shared alignment pass. Both layout and the final view drawing pass align icon, heading and message to
the native 20-point leading inset. Alignment applies to the image inside its frame and to attributed paragraph runs as well as the
text-field property; an attributed centered paragraph can otherwise remain visibly centered while the cell reports left alignment.
Preserve native buttons, fonts, complete messages and alert appearance. Do not add per-module confirmation layouts.

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

`results/stable-flags-20261018/verified-all-tests.txt`: 481 tests, 477 passed and four optional tests skipped. This follow-up covers
stable row widths, original native text transitions and single-line page actions. Regression tests exercise the reported Portuguese labels under narrow intermediate proposals, fixed flag widths across
progress/result text, capped notices, counter identities and optional action-label serialization. Visual animation verification
remains with the user; supplied recording frames were read as files without controlling the application.

`results/compact-free-20261018/app-tests.txt`: 117 App tests, 115 passed and two optional snapshots skipped. Idle flag sizing fits
the title plus normal padding in English, Portuguese and Japanese; progress/result retain the fixed reservation and neighbouring
control footprint. The orange action remains one line at 31 points high.

`results/digits-cleanup-handoff-20261018/all-tests.txt`: 492 tests, 488 passed and four optional skips. Regression coverage includes
caption font metrics for 31,11 GB and 2,21 GB, explicit tabular callers, digit/phrase identities, fixed progress widths, both cleanup
entry points, unrelated target/error results and interrupted dock departures. `localize.txt` verifies all eight UI languages.
The supplied 04.03.56 recording was sampled as a file: its loading phrase overshoots the tile's right edge and overlaps the unrelated
status during the numeric transition. Visual verification of the new motion remains with the user; no GUI automation was used.

`results/text-anchor-20261018/all-tests.txt`: 492 tests, 488 passed and four optional skips. This supersedes the phrase-identity
roll and the reservation across unrelated phases above. Offscreen checks cover proportional caption metrics, fixed percentage
field width through 100%, a stable All done numeric field, phase-specific row widths and the one-line 31-point button. Both supplied
04.20.16 and 04.24.36 recordings were decoded as files. Runtime motion still requires the user's visual verification.

`results/confirmation-spacing-20261018/all-tests.txt`: 496 tests, 492 passed and four optional skips. The final focused run in
`final-targeted-tests.txt` covers the maximum-100% reservation, inherited trailing paragraph alignment, row phase/fraction changes,
pill geometry and alert pre-draw correction. Alert cases exercise all three native styles, short/long text, Portuguese cache
confirmation, Japanese, About, startup and uninstall wording, including centered attributed paragraph styles after native relayout.
All app-owned alert constructors were audited to use AppAlert; localization checks passed. Supplied video frames were decoded
from the recording file; final visual verification remains with the user.

`results/loading-right-edge-20261018/reproduce.txt` reproduces the extra visible right inset in the previous reserved-percentage
layout. `tests.txt` verifies the corrected rendered edge at 1%, 9%, 11%, 59%, 64%, 99% and 100%, at caption sizes 16, 18 and 22,
plus natural word/sign spacing, steady equal-length progress widths and preserved byte-figure metrics. This supersedes the earlier
percentage reservation; explicit All done counting reservations remain in place.

`results/loading-right-edge-20261018/all-tests.txt`: 497 tests, 493 passed and four optional skips.

`results/word-motion-20261018/final-motion-tests.txt` verifies numeric/phrase routing, stale completion cancellation, frozen fonts
and bounds, Unicode/whitespace, unchanged word matching, Reduce Motion, rendered intermediate right bounds, complete target
pixels for caption/flag/button/All done fonts and alignments, wrapped text and capped single-line ellipses. Truncated glyph
contours allow one device pixel for the two native drawing paths' fractional-origin quantization; fitting labels match exactly.
The renderer's exported time samples are in `results/word-motion-20261018/frames/` and `word-change.gif`; these are offscreen
component frames, not a recording of the application. Runtime visual verification remains with the user.

`results/word-motion-20261018/all-tests.txt`: 506 tests, 502 passed and 4 optional skips; localization checks passed.

`results/issue-review-20261018/all-tests.txt`: 510 tests, 505 passed and five optional skips. Manual and quiet scan tests now also
check the dock's current phase: Loading while scanning, no action after a no-action page finishes. Footer generation tests cover
render/observer ordering, repeated absent phases and cancellation by a newer appearance. Analytics tests reject both false failure
and false success from history timestamps, preserve real post-change IN/OUT evidence, and keep raw helper diagnostics out of UI
copy. Compiler localization extraction passed for all eight languages. The final Siri button disappearance/fade requires the
user's visual check.

The notification investigation on 2026-10-18 found that macOS's **Allow Notifications** for MacSpace was disabled, confirmed by the
user in System Settings. This blocks all notification types regardless of the app's own switches. No notification rules were
changed; the user enables that permission in System Settings. No UI automation was used.
