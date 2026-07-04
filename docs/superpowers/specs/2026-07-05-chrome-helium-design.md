# Chromeless Helium Chrome — Design Spec

> **Status:** Approved  
> **Date:** 2026-07-05  
> **Project:** Chromeless  
> **Files:** `main.swift` (single-file AppKit application)

## 1. Overview

Redesign the Chromeless browser chrome to adopt a Helium-inspired aesthetic: pill-style tabs with uniform corner radius, a centered URL pill, left-anchored navigation buttons, and careful layout of every UI/UX element. The fundamental layout is **Classic** (tabs below traffic lights, address bar row below tabs).

## 2. Tab Bar

### 2.1 Dimensions

| Property | Value | Notes |
|----------|-------|-------|
| Bar height | 36 pt | Full width of window |
| Traffic light inset | 78 pt | Left padding for tabs to clear window controls |
| Right inset | 8 pt | Padding before edge |
| Top inset | 4 pt | Clearance above the 30 pt tab (uniform for all tabs) |
| Bottom margin | 2 pt | Applied uniformly below all tabs to satisfy bottom-alignment |

**Uniform height:** Following Chrome-Refresh / Helium, all tabs are the **same height** (30 pt) regardless of selection. The active tab is distinguished by a filled background pill, not by being taller — this avoids vertical reflow jank on selection change.

### 2.2 Tab Items

| Property | Value | Notes |
|----------|-------|-------|
| Shape | Pill — uniform 8 pt corner radius | All four corners, not just top (`CGPath(roundedRect:)`) |
| Overlap | None | 4 pt gap between adjacent tabs (`NSStackView.spacing = 4`) |
| Height | 30 pt (uniform) | Same for active and inactive; bottom-aligned within the 36 pt bar |
| Min width | 120 pt | Below this: tab bar scrolls |
| Max width | 400 pt | Cap only; tabs **stretch to share the available strip width** (Helium/Chrome expand-to-fill). Few tabs → wide, filling toward the window edge; more tabs → shrink toward min. Width = `clamp(available / count, 120, 400)`, recomputed on resize |
| Background (active) | `calibratedWhite 0.17` (~`#2b2b2b`) | Filled *lighter* surface pill floating above the darker strip (Helium), not near-black; distinguishes selection instead of extra height |
| Background (hover) | `rgba(255,255,255,0.08)` | Inactive tabs only |
| Background (default) | Transparent | Inactive, not hovered |
| Text color (active) | `#ffffff` | — |
| Text color (hover) | `#cccccc` | — |
| Text color (default) | `#999999` | — |
| Font size | 12 pt | System font |
| Font weight | Regular (all states) | **No weight change** — Chrome/Helium never bolds the active tab; also prevents layout jank |

**Active tab height anchor:** Bottom-aligned. Even though a separate address-bar row breaks the classic "merge with content" illusion, bottom-alignment is the browser convention and matches the current implementation's `.bottom` alignment on `tabStack` + `edgeInsets(top: 4, ...)`.

### 2.3 Tab Content Layout

```
┌─────────────────────────────────────┬─────┐
│  [favicon]  Tab Title …             │  ✕  │
└─────────────────────────────────────┴─────┘
    ↑ 10pt    ↑ 5pt gap   ↑ ellipsis        ↑ 8pt
```

- **Favicon:** 16×16 pt, left-aligned, 10 pt from leading edge
- **Loading spinner:** Replaces favicon frame while page is loading (NSProgressIndicator, `.spinning` style, small control size)
- **Title:** Single line, `.byTruncatingTail` ellipsis at min-width floor
- **Close button:** 16×16 pt SF Symbol `xmark` / `xmark.circle.fill` — same size as favicon.
  - **Favicon→Close reveal:** Two independent, fixed-position elements — not frame-shared. Favicon sits at the left edge (10 pt from leading). Close button sits at the right edge (8 pt from trailing). On hover: favicon and loading spinner are hidden; close button becomes visible at its own right-side position. Both elements are 14×14 pt, so no size pop on state change. This matches the Chrome/Firefox/Safari convention of separate left/right icon slots rather than a single shared frame.
  - Visibility: Close visible on active tabs always; on inactive tabs, visible only on hover.
  - Icon: `xmark.circle.fill` (filled circle) for active tab, `xmark` (thin) for inactive/hovered.
- **Spacing:** 5 pt gap between favicon and title; 8 pt padding on each side.

### 2.4 Overflow Behavior

- **Shrink floor:** Tabs compress to 100 pt minimum width
- **Scroll trigger:** When sum of min-widths + gaps + new-tab button exceeds available width
- **Mechanism:** Tab stack inside an NSScrollView with `.horizontal` scroller (hidden unless actively scrolling)
- **Input:** Mouse wheel horizontal scroll, trackpad swipe, shift-scroll
- **Fade indicators:** Optional — CSS-style gradient masks on scroll edges (deferred, cosmetic)
- **New-tab button:** **Pinned outside scrollable region.** The "+" button sits in the tab bar's unclipped trailing area, always visible regardless of scroll position.
- **Auto-scroll on selection:** Programmatic tab selection (Ctrl+Tab MRU, ⌘1-9 shortcuts, keyboard) calls `scrollRectToVisible` on the selected tab's frame. Clicking an already-visible tab skips scroll.

### 2.5 New-Tab Button

- Fixed-width 26×26 pt button at the right end of the tab bar
- SF Symbol `plus`, `.secondaryLabelColor` tint
- **Not wrapped** in the scrollable NSStackView — sits in the tab bar's unclipped area
- Rounded rect background (6 pt corner radius) on hover

## 3. Address Bar Row

### 3.1 Layout

```
┌──────────────────────────────────────────────────────────────┐
│  [◀][▶][↻]                  [🔒 google.com]                  │
│  ← fixed, left-anchored →    ← centered pill, max 560pt →    │
└──────────────────────────────────────────────────────────────┘
    ↑ nav buttons outside pill    ↑ URL + security + actions
```

| Property | Value | Notes |
|----------|-------|-------|
| Row height | 40 pt | Below tab bar |
| Separator above | 1 pt | `rgba(255,255,255,0.06)` between tab bar and this row |

### 3.2 Navigation Buttons

- **Position:** Left-anchored, fixed position outside the URL pill
- **Rationale (Fitts's law):** The URL pill is centered and shifts with window width. Putting back/forward inside it would make the back button's screen position unpredictable, breaking muscle memory. Anchoring them left preserves a stable click target.
- **Buttons:** Back (`chevron.left`), Forward (`chevron.right`), Reload (`arrow.clockwise`)
- **Size:** 26×26 pt each
- **Corner radius:** 6 pt (hover background)
- **Hover background:** `rgba(255,255,255,0.12)`
- **Spacing:** 2 pt gap between buttons
- **Left padding:** 2 pt from the row edge

### 3.3 URL Pill

- **Centered** within the row's remaining space
- **Max width:** 560 pt
- **Min width:** 200 pt
- **Height:** 32 pt
- **Corner radius:** 16 pt (fully rounded pill shape — half of 32 pt height, the geometric maximum for stadium rounding)
- **Background:** `calibratedWhite 0.17` (~`#2b2b2b`, neutral gray) — shares the same "surface" tone as the active tab pill, per Helium. (Earlier drafts used a blue-tinted `#1c1c28`; Helium's omnibox is neutral gray, so the tint was dropped.)
- **Border:** 0.5 pt, `rgba(255,255,255,0.08)`
- **Elevation:** `0 1px 4px rgba(0,0,0,0.3)` box shadow

#### URL Field Layout Inside Pill

```
┌──────────────────────────────────────────┐
│  🔒  google.com                    ☆    │
│  ↑ 10pt  ↑ 6pt            ↑ bookmark    │
└──────────────────────────────────────────┘
```

- **Security icon:** `lock.fill` (HTTPS, `.tertiaryLabelColor`) or `globe` (HTTP, `.secondaryLabelColor`) or `magnifyingglass` (search/start page, `.secondaryLabelColor`)
- **URL text:** 14 pt, `.labelColor`, `.byTruncatingHead` line break mode
- **Background when not editing:** Transparent (the pill itself provides the background)
- **Edit state:** Signaled by border glow only (`controlAccentColor` at 40% opacity, 1 pt border). Background unchanged — the text field is always transparent and the pill's resting background (`#1c1c28`) provides the base.
- **Right-side action button:** Bookmark star (SF Symbol `star`) — optional, shows `.secondaryLabelColor` when not bookmarked, `.systemYellow` when bookmarked
- **Separator lines:** 1 pt vertical dividers at `rgba(255,255,255,0.06)` between nav buttons and pill, and optionally between URL field and right action button

### 3.4 URL Field (NSTextField)

- No bezel, no border, no background (transparent; pill background shows through)
- Focus ring: none (managed by pill border glow)
- Placeholder: "Search Google or type a URL" in `.secondaryLabelColor`
- **Alignment:** centered (minimal Helium omnibox) for both the placeholder and the resting URL; switches to left-aligned (`.natural`) while the field is focused/editing. Field is a fixed height, vertically centred inside the pill (an editable `NSTextField` does not vertically centre its own text), with symmetric left/right margins so centred text lands on the pill's centre.
- Truncation: `.byTruncatingHead` (shows the end of long URLs)
- Delegate handles: Enter → navigate, Escape → cancel + refocus webview
- **Click-to-focus:** a single-click `NSClickGestureRecognizer` on the pill focuses the field (native click-to-focus is unreliable here — movable-by-background window + the field not filling the whole pill). A gesture delegate declines once the field editor is active so subsequent clicks reach it for cursor placement / selection.
- **New blank tab → address bar focus:** opening a blank new tab (⌘T, "+") drops the caret into the address bar so the user can type immediately. The focus call is deferred one tick because a freshly-added `WKWebView` grabs first responder on its first display and would otherwise steal it back.

### 3.5 Titlebar Double-Click

- Double-clicking an **empty area of the tab bar** (the titlebar-equivalent row) behaves like double-clicking a native window titlebar (our custom chrome covers the real titlebar, so this is wired manually via a 2-click `NSClickGestureRecognizer`). The recognizer is **not** attached to the address-bar row — an ancestor recognizer there would swallow the click that focuses the editable URL field, breaking typing.
- Honours **System Settings ▸ Desktop & Dock ▸ "Double-click a window's title bar to"** (`AppleActionOnDoubleClick`): `Maximize`/unset → `window.zoom`, `Minimize` → miniaturize, `None` → no-op.
- Clicks on tabs, buttons, or the URL field keep their own behaviour (tab select, word-select, etc.) — controls consume the event before it reaches the bar's recognizer.

## 4. Tab Manager Interactions

### 4.1 Tab Switch Animation

- Current tab fades out (alpha 1 → 0) over 0.12s
- New tab animates in simultaneously (alpha 0 → 1) over 0.12s
- Uses `NSAnimationContext` with default curve

### 4.2 Tab Close Animation

- No animation on close for v1 — tab is removed immediately and remaining tabs reflow
- Future: sliding close animation (v2)

### 4.3 MRU Tab Cycling (Ctrl+Tab / Ctrl+Shift+Tab)

- Most-recently-used order maintained in `TabManager.mruOrder`
- Ctrl+Tab: cycle forward through MRU order
- Ctrl+Shift+Tab: cycle backward
- Auto-scrolls tab bar to reveal selected tab if scrolled out of view

### 4.4 Keyboard Tab Selection (⌘1-9)

- ⌘1 selects first tab, ⌘2 selects second, … ⌘9 selects ninth
- `onTabSwitch` callback on `BrowserWebView`
- Auto-scrolls tab bar if needed

## 5. V1 Exclusions (Explicit)

The following are **not in scope** for this design and are deferred to v2:

- **Pinned tabs** — compact, domain-only, persistent tabs
- **Drag-to-reorder tabs** — drag-and-drop within the tab bar
- **Tab overflow gradient fade** — visual fade on scroll edges
- **Tab close animation** — smooth sliding close
- **Tab grouping / vertical tabs** — sidebar or stacked tab groups

## 6. Implementation Plan

See `docs/superpowers/plans/YYYY-MM-DD-chrome-helium-implementation.md` (separate document).

## 7. Spec Self-Review

- [x] **Placeholder scan:** No TODOs, TBDs, or incomplete sections
- [x] **Internal consistency:** Dimensions, colors, and layout rules are coherent across sections
- [x] **Scope check:** Focused entirely on chrome redesign for a single file; no scope creep
- [x] **Ambiguity check:** Tab height anchor, overflow behavior, nav button placement, and favicon/close swap are all explicitly resolved

### Implementation Notes

- **Tab text colors** use semantic `NSColor` equivalents (`.labelColor`, `.secondaryLabelColor`, `.tertiaryLabelColor`) rather than literal hex values (`#ffffff`, `#cccccc`, `#999999`). This tracks system appearance including light-mode and accessibility contrast settings. Deviation from spec hex values is intentional for system-compatibility reasons.
