# Module layout experiment

Branch: `ui-exp-unplanned`, based on `fix-imp-v116`.

Module content uses one, two or three columns according to the available width. Window sizing, zoom, full-screen behavior,
dashboard tiles and the cleaning button's bottom-left placement are unchanged.

## Layout

- Existing 700-point windows keep one column, the existing margins and the 150-point storage chart.
- At 924 points of page width, complete sections flow into two columns. At 1368 points they flow into three columns.
  These thresholds include the existing 30-point margins on each side and 24-point column gaps, keeping columns at least
  420 points wide. A smaller full-screen display uses fewer columns to keep its controls readable.
- Wider windows center the grid and cap each column at 480 points. A single column is capped at 820 points.
- Storage overview charts and legends occupy the first grid cell, beside the cleanup and information sections. Charts
  in these narrower columns gain height, bounded between 180 and 240 points. Legends allow two lines for category names.
- Debloat and Siri distribute complete sections in the same grid. Sections retain their declared reading order, left to
  right and then down. They are not packed by height; individual rows never move between sections.
- Nested group and selection pages keep one centered list so ordered files and selection groups remain easy to scan.
- The page has one scroll area. The grid and the existing lazy row stacks retain stable IDs across width changes.
  The footer reserve remains outside the grid, so its spacer cannot become an empty column cell.
- Main action, progress and completion overlays retain their existing placement and behavior.

## Verification

`ModulePageLayoutTests` covers compact, medium, three-column, ultrawide, narrow-display, initial-geometry and drill-down
layouts. Existing page cascade, selection, action dock and row cleanup tests should also run before merging.

On macOS 27 with Xcode 27:

```sh
swift test
swift Scripts/Localize.swift --check
```

Visual checks still required on a Mac:

1. Open each of the four modules at 700, 1000, 1440 and 1920 points wide, including full screen and a short tiled window.
2. Resize across both thresholds with a section expanded and with a cleanup running. Verify that controls retain their state,
   no scan or entrance cascade restarts, and rows remain readable in English, German and Portuguese.
3. Open a nested list, choose items, resize and return. Check selection, Back navigation, scroll position and lazy row behavior.
4. Scroll the last row above the unchanged cleaning button. Verify progress, warnings and completion still use the same dock.
5. Check reduced motion, keyboard navigation and VoiceOver reading order.

This experiment does not change feature settings, cleaning actions or release configuration.
