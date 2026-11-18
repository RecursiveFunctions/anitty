# Changelog

All notable changes to Anitty (the unofficial Win32 Ghostty fork) are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versions follow the Windows packaging string (`1.4.1-windows` and tagged builds such as `windows-v1.4.1-windows.*`).

## [Unreleased]

## [1.4.1-windows.18895.gfb7a033] — 2026-11-17

Release: [`windows-v1.4.1-windows.18895.gfb7a033`](https://github.com/RecursiveFunctions/anitty/releases/tag/windows-v1.4.1-windows.18895.gfb7a033).

### Fixed

- **Win32 context menu / mouse reports**: Clear mouse capture, `mouse_buttons`, and `click_state` before `TrackPopupMenuEx` so dismissing a Shift+right-click (or Menu key) context menu no longer leaves the right button stuck “held” in SGR mouse reports (upstream #15260 / #11342).
- **Win32 overlays**: Command Palette and Tab Overview are mutually exclusive; overlays hide or refresh when tabs/surfaces change so closed surfaces are never kept as stale `.jump` pointers.
- **Win32 window sizing**: `window-width` / `window-height` honor the tab bar on initial launch (`window-show-tab-bar = always`) and when only one dimension is configured (upstream #14157).
- **OpenGL export orientation**: Frame export blits top-row-first (`blitToExport`); redundant GTK snapshot Y-flip removed (upstream #15207).
- **Color emoji / color glyphs**: Decode premultiplied sRGB color glyphs correctly under linear blending (OpenGL + Metal shaders; upstream #14967).
- **HarfBuzz fallback faces**: If a deferred fallback face fails to load, fall back to the primary regular face instead of blanking the whole row (upstream #15216).
- **Scrollback search**: Memoize page-node validity in `pruneHistory` so pruning large match sets is not `O(matches × pages)` (upstream #15272).
- **libghostty-vt / DECSLRM snapshots**: Preserve `pending_wrap` at a scrolling-region right margin and keep `semantic_prompt` across partial-row clones when left/right margins are active (upstream #15265 / #15266).

### Changed

- Shared `Window.palette` / `Surface.palette` drive Tab Bar, Command Palette, Tab Overview, Search Overlay, and Surface Overlay colors (including OSC 10/11 dynamic fg/bg).
- Overlay sync on tab move/transfer, split focus, relayout, and color changes; `setInitialSize` / `place` / `resetWindowSize` go through `configuredOuterSize`.
- Snapshot `pending_wrap` checks simplified; kaitai verifier allows DECSLRM right margins.

Commits: `8f6f91bac`, `3a7ab0383` (on top of `3fb0cc4dd`).

## [1.4.1-windows] — prior tagged builds

See GitHub [Releases](https://github.com/RecursiveFunctions/anitty/releases) for installer/portable artifacts tagged `windows-v1.4.1-windows.*`. Detailed notes for earlier tip commits live in those release pages until backfilled here.
