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
controls through the capsule's presented width. `PillMorph` measures/places its destination with an unspecified proposal, independent
of the parent's intermediate allocation. The surrounding HStack has no second phase spring: its controls follow that single width
each frame. A second spring and proposal-dependent measurements repeatedly squeezed the warning badge and retargeted the flag.
Fraction-only ticks do not retarget the shell; Reduce Motion updates its width immediately.

Cells (including shade and separator), headers and sections use SwiftUI's `geometryGroup()` before their cascade modifiers. This
resolves ancestor placement as one transform before descendants' independent text transactions; labels and pill text cannot cancel
the cell's motion and detach from its background. This is the row-animation use described in
[Apple's geometryGroup documentation](https://developer.apple.com/documentation/swiftui/view/geometrygroup()). Text/number content
motion retains its existing renderer, anchors and timings.

The form's flattened item identities, rather than only section ids, drive structural layout. `PageCascade.Structure` preserves the
previous whole-page order/offset/count. Gap closure waits for the latest departing item's existing reverse-cascade delay plus its
0.22-second duration, then uses `Theme.layout` to move survivors and following sections together. Initial loads, numeric/status
updates, reorder-only changes and insertions add no departure delay. New changes are ordinary SwiftUI transactions, with no timers
or stale asynchronous removal callbacks. Reduce Motion retains opacity departure and closes the gap without spatial animation.

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

The refresh, loading, cleanup and motion behavior above is covered by automated tests (the last full run of this series: 513 tests,
508 passed, five optional tests skipped: live CacheDelete opt-ins and saved render snapshots) and by localization checks in all
eight languages. The tests cover live and manual refresh, immediate loading captions, retained choices, stale reads, targeted partial
cleanup, excluded clones, repeated purges, shared cloud progress, All done verification, inline permission failures, confirmation
frames, window presence, the text-motion rules (numeric and phrase routing, stale-completion cancellation, Reduce Motion, fixed
percentage and byte-figure widths through 100%), pill geometry with intrinsic measurement, and alert alignment for all three native
styles. Motion and animation are checked by the maintainer by eye; no GUI automation is used.

macOS's **Allow Notifications** for MacSpace was found disabled during the 2026-10-18 notification investigation. That setting blocks
every notification type regardless of the app's own switches; the user enables it in System Settings, and MacSpace changes no
notification rules.

Main sources: `App/Registry/ModuleHandle.swift`, `App/Registry/ModuleHost.swift`, `App/Shell/MainView.swift`, `App/Renderer/ScreenView.swift`, `Sdk/Contract/Module.swift`, `Sdk/Interface/Tile.swift`, and each module's snapshot store/screen builder.

## Feature model cleanup (2026-10-18)

Siri and Spatial Photos use the existing ToggleRow control; Phone combines local preferences with verified post-restart gates. The AI language control remains first. Changing a feature reconciles switch state only. Cleanup completion reconciles model measurements and assets without a full-page reload. The module requests five-second presentation polling during active feature cleanup, with existing badges and text transitions.

The separate default-enabled `featureModels` background task checks explicitly managed-off Siri, Phone and Spatial Photos controls every 300 seconds while MacSpace is open; the optional 900-second AI watch remains separate. Shared owner operations run in the signed CLI, and one guarded CacheDelete pass serves a batch. Unknown eligibility stops new owner cleanup and its deferred purge attempts. Empty target inventories do not start another purge. System Data retains the `purgeAssets` action identity and `Row.activity` flag during model-cleanup background retries.

Implementation and validation: [Issue 16 implementation reference](Research.md#issue-16-implementation-reference).
