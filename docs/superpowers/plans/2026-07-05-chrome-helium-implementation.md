# Chrome-Helium Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor Chromeless tab bar and address bar to match the Helium-inspired design spec (docs/superpowers/specs/2026-07-05-chrome-helium-design.md).

**Architecture:** Single-file AppKit application (`main.swift`, ~2683 lines). All changes go into this one file. Changes are split into four sequential tasks that build on each other: (1) TabBarItem pill shape + visual polish, (2) Tab bar layout spacing + overflow scroll, (3) URL pill and toolbar row, (4) Auto-scroll on keyboard selection.

**Tech Stack:** Swift, AppKit (Cocoa), WKWebView, NSVisualEffectView, NSScrollView, CAShapeLayer

---

### Task 1: TabBarItem — Pill Shape, Sizes, Favicon/Close Swap

**Files:**
- Modify: `main.swift:612-795` (TabBarItem class, entire)

This task converts TabBarItem from Chrome-style rounded-top tabs to uniform pill tabs with correct dimensions and eliminates the font-weight jank.

- [ ] **Step 1: Replace shape-path mask with simple cornerRadius**

Remove the CAShapeLayer approach. TabBarItem uses `layer.cornerRadius = 7` and `layer.masksToBounds = true` instead. Delete `tabShapePath()`, `updateShapePath()`, `_pathCache`, and the `shapeLayer` property. Delete the `updateShapePath()` call from `layout()`.

In `init(frame:)` (the `super.init(frame: .zero)` line), add after `wantsLayer = true`:
```swift
layer?.cornerRadius = 7
layer?.cornerCurve = .continuous
```

Delete the `shapeLayer` property:
```swift
// DELETE:
private var shapeLayer: CAShapeLayer?
```

Delete these methods entirely:
```swift
// DELETE entire block:
private static let _pathCache = NSCache<NSString, CGPath>()
private func tabShapePath(size: CGSize) -> CGPath { ... }

private func updateShapePath() {
    guard bounds.width > 0, bounds.height > 0 else { return }
    if shapeLayer == nil {
        let mask = CAShapeLayer()
        mask.frame = bounds
        mask.fillColor = NSColor.black.cgColor
        layer?.mask = mask
        shapeLayer = mask
    }
    shapeLayer?.frame = bounds
    shapeLayer?.path = tabShapePath(size: bounds.size)
}
```

In `layout()`, remove the call:
```swift
// DELETE this line:
updateShapePath()
```

- [ ] **Step 2: Fix favicon and close button to both be 14×14**

Change `iconSize` and `closeSize` in `layout()`:

```swift
override func layout() {
    super.layout()
    let h = bounds.height
    let pad: CGFloat = 10
    let iconSize: CGFloat = 14       // was 16
    let closeSize: CGFloat = 14      // was 16
    let gap: CGFloat = 5             // was 6

    faviconView.frame = NSRect(x: pad, y: (h - iconSize) / 2, width: iconSize, height: iconSize)
    loadingSpinner.frame = faviconView.frame

    let titleX = pad + iconSize + gap
    let closeW = closeSize + 6       // slightly more hit area than icon
    let titleW = bounds.width - titleX - pad - closeW
    titleLabel.frame = NSRect(x: titleX, y: 0, width: max(0, titleW), height: h)

    closeButton.frame = NSRect(x: bounds.width - pad - closeSize, y: (h - closeSize) / 2,
                                width: closeSize, height: closeSize)
}
```

- [ ] **Step 3: Fix updateAppearance — no font-weight change, correct colors, favicon/close swap**

Replace the existing `updateAppearance()` method:

```swift
func updateAppearance() {
    let pageBG = NSColor(calibratedWhite: 0.04, alpha: 1)
    if isSelected {
        layer?.backgroundColor = pageBG.cgColor
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close tab")
        closeButton.contentTintColor = .secondaryLabelColor
        titleLabel.textColor = .labelColor
        closeButton.isHidden = false
        faviconView.isHidden = false
    } else if isHovered {
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")
        closeButton.contentTintColor = .tertiaryLabelColor
        titleLabel.textColor = .secondaryLabelColor
        faviconView.isHidden = true    // swap favicon → close
        closeButton.isHidden = false
    } else {
        layer?.backgroundColor = NSColor.clear.cgColor
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")
        closeButton.contentTintColor = .tertiaryLabelColor
        titleLabel.textColor = .secondaryLabelColor
        faviconView.isHidden = false
        closeButton.isHidden = true
    }
    // Font weights stay regular everywhere — no semibold/regular switch
    titleLabel.font = .systemFont(ofSize: 12)
}
```

- [ ] **Step 4: Fix TabBarItem init — remove stale references**

In `init(index:title:favicon:isSelected:isLoading:target:clickAction:closeAction:secondaryAction:)`:

Remove these lines that are no longer needed:
```swift
// DELETE these lines from init:
// was setting font based on isSelected:
titleLabel.font = isSelected ? .systemFont(ofSize: 12, weight: .semibold) : .systemFont(ofSize: 12)
// replace with just:
titleLabel.font = .systemFont(ofSize: 12)
```

Also update the close button size reference in the closeButton setup (it uses `closeSize` directly from layout, so init is fine).

- [ ] **Step 5: Commit**

```bash
git add main.swift
git commit -m "tabs: convert TabBarItem to uniform pill shape, 14×14 favicon/close, no font-weight jank"
```

---

### Task 2: Tab Bar Layout — Gap Instead of Overlap, Overflow Scroll, Pinned "+" Button

**Files:**
- Modify: `main.swift:985-1010` (tab bar constants and properties)
- Modify: `main.swift:1495-1510` (buildChrome — tab bar setup)
- Modify: `main.swift:1724-1813` (layoutOverlays — tab bar frames)
- Modify: `main.swift:1334-1390` (refreshTabBar — tab stack population)

This task changes tab spacing from overlapping (-8) to gapped (4pt), adds overflow scroll behavior, and pins the "+" button outside the scrollable region.

- [ ] **Step 1: Add tabScrollView property to BrowserWindowController**

Near the other tab bar properties (around line 985):
```swift
private let tabScrollView = NSScrollView()
```

- [ ] **Step 2: Set up tabScrollView in buildChrome**

In `buildChrome(in container:)`, after the tabStack setup block (~line 1505):

Replace:
```swift
tabStack.orientation = .horizontal
tabStack.spacing = -8
tabStack.alignment = .bottom
tabStack.edgeInsets = NSEdgeInsets(top: 4, left: trafficLightInset, bottom: 0, right: 8)
tabStack.translatesAutoresizingMaskIntoConstraints = false
tabBar.addSubview(tabStack)
```

With:
```swift
tabStack.orientation = .horizontal
tabStack.spacing = 4          // was -8 — no overlap
tabStack.alignment = .bottom
tabStack.edgeInsets = NSEdgeInsets(top: 4, left: trafficLightInset, bottom: 2, right: 0) // bottom: 2 added for bottom margin
tabStack.translatesAutoresizingMaskIntoConstraints = false

tabScrollView.documentView = tabStack
tabScrollView.hasHorizontalScroller = false
tabScrollView.hasVerticalScroller = false
tabScrollView.drawsBackground = false
tabScrollView.translatesAutoresizingMaskIntoConstraints = false
tabBar.addSubview(tabScrollView)
```

- [ ] **Step 3: Update refreshTabBar — remove zPosition, add "+" button outside scroll**

In `refreshTabBar()`, remove the zPosition line:
```swift
// DELETE:
item.layer?.zPosition = isSelected ? 10 : CGFloat(tabItems.count - i)
```

Change the tab item height to 28 for inactive, and keep 30 for active by modifying the constraint block:

```swift
NSLayoutConstraint.activate([
    item.heightAnchor.constraint(equalToConstant: isSelected ? 30 : 28),
    item.widthAnchor.constraint(greaterThanOrEqualToConstant: 100),   // was 120
    item.widthAnchor.constraint(lessThanOrEqualToConstant: 240),
])
```

The addBtn (+ button) should NOT be added to tabStack anymore. Instead, add it directly to tabBar:
```swift
// Replace: tabStack.addArrangedSubview(addBtn)
tabBar.addSubview(addBtn)
```

Also update addBtn constraints — remove the old `addBtn.translatesAutoresizingMaskIntoConstraints = false` block and replace with frame-based positioning (managed in layoutOverlays):
```swift
addBtn.translatesAutoresizingMaskIntoConstraints = true
// Remove the old NSLayoutConstraint.activate block for addBtn
```

Keep the rest of the addBtn setup (title, image, target, action, wantsLayer, cornerRadius).

- [ ] **Step 4: Update layoutOverlays — frame positions for tabScrollView and "+" button**

In `layoutOverlays()`, replace the tab bar frame section (this references `tabAddButton` which is set up in Step 5):

```swift
tabBar.frame = NSRect(x: 0, y: b.height - tabBarHeight, width: b.width, height: tabBarHeight)

let addBtnSize: CGFloat = 26
let addBtnTrailing: CGFloat = 8
let scrollableWidth = b.width - addBtnSize - addBtnTrailing
tabScrollView.frame = NSRect(x: 0, y: 0, width: scrollableWidth, height: tabBar.bounds.height)
tabStack.frame = NSRect(
    x: 0, y: 0,
    width: max(tabStack.fittingSize.width, tabScrollView.bounds.width),
    height: tabScrollView.bounds.height)

// "+" button pinned at trailing edge of tabBar, outside scroll area
tabAddButton.frame = NSRect(
    x: scrollableWidth,
    y: (tabBar.bounds.height - addBtnSize) / 2,
    width: addBtnSize,
    height: addBtnSize)
```

- [ ] **Step 5: Update the addBtn reference**

The `addBtn` is created as a local variable in `refreshTabBar()`. It needs to be a stored property or referenced differently since it's used in `layoutOverlays()`. The cleanest approach: make it a stored property on BrowserWindowController.

Near the other chrome properties (~line 990), add:
```swift
private let tabAddButton = NSButton()
```

In `refreshTabBar()`:
- Replace `let addBtn = NSButton(...)` with just setup of `tabAddButton`
- Set up `tabAddButton` the same way (image, target, action, etc.)
- Add to `tabBar` instead of `tabStack`: `tabBar.addSubview(tabAddButton)`

In `layoutOverlays()`:
- Replace `addBtn` references with `tabAddButton`

Change `newTabFromBar(_:)` target if needed — `tabAddButton.action` should point to `#selector(newTabFromBar(_:))`.

- [ ] **Step 6: Update tabBarSeparator position**

In `layoutOverlays()`, update the separator to draw below the tab bar:
```swift
// was: tabBarSeparator.frame = NSRect(x: 0, y: toolbarY + toolbarHeight - 1, ...)
// Keep as-is — the separator sits between tab bar and toolbar row
```

- [ ] **Step 7: Commit**

```bash
git add main.swift
git commit -m "tabs: 4pt gap, overflow scroll, pinned new-tab button, bottom margin"
```

---

### Task 3: URL Pill and Toolbar Row — Nav Buttons Outside, Correct Dimensions

**Files:**
- Modify: `main.swift:987-1000` (constants)
- Modify: `main.swift:1489-1552` (buildChrome — address bar setup)
- Modify: `main.swift:1724-1813` (layoutOverlays — address bar frame)
- Modify: `main.swift:1250-1265` (centeredLocationBarFrame and updateURLField)

This task updates the URL pill to the correct dimensions (16pt radius, 560pt max width, edit-state border glow) and ensures nav buttons are properly left-anchored outside the pill.

- [ ] **Step 1: Update URL pill constants**

```swift
private let centeredLocationBarMaxWidth: CGFloat = 560   // was 700
```

- [ ] **Step 2: Update URL pill visual styling in buildChrome**

In the `buildChrome` method, update the `locationBar` setup:

```swift
locationBar.wantsLayer = true
locationBar.material = .contentBackground
locationBar.blendingMode = .withinWindow
locationBar.state = .active
locationBar.layer?.cornerRadius = 16              // was 8 — max for 32pt height
locationBar.layer?.cornerCurve = .continuous
locationBar.layer?.masksToBounds = true
locationBar.layer?.borderWidth = 0.5
locationBar.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
locationBar.layer?.backgroundColor = NSColor(calibratedWhite: 0.11, alpha: 1).cgColor
// Add shadow
locationBar.shadow = NSShadow()
locationBar.layer?.shadowColor = NSColor.black.withAlphaComponent(0.3).cgColor
locationBar.layer?.shadowOffset = NSSize(width: 0, height: 1)
locationBar.layer?.shadowRadius = 4
locationBar.layer?.shadowOpacity = 1
```

- [ ] **Step 3: Update edit state — border glow only**

In `controlTextDidBeginEditing(_:)`, change the URL field edit state styling:

```swift
func controlTextDidBeginEditing(_ obj: Notification) {
    if obj.object as? NSTextField == urlField {
        // Border glow only — background stays the same
        locationBar.layer?.borderWidth = 1.5
        locationBar.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.4).cgColor
    }
}
```

In `controlTextDidEndEditing(_:)`:
```swift
func controlTextDidEndEditing(_ obj: Notification) {
    if obj.object as? NSTextField == urlField {
        locationBar.layer?.borderWidth = 0.5
        locationBar.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
    }
}
```

- [ ] **Step 4: Update centeredLocationBarFrame for new max width**

The `centeredLocationBarFrame` method already uses `centeredLocationBarMaxWidth` — now 560. Verify the calculations. The nav buttons remain left-anchored outside the pill as already implemented. No changes needed to the nav button positioning in `layoutOverlays()` — they're already outside the pill.

- [ ] **Step 5: Update separator position**

The toolbar separator (`tabBarSeparator`) should sit between the tab bar and the address bar row. Its current position (`toolbarY + toolbarHeight - 1`) should still be correct.

- [ ] **Step 6: Commit**

```bash
git add main.swift
git commit -m "chrome: URL pill 16pt radius, 560pt max, edit-state border glow"
```

---

### Task 4: Auto-Scroll on Keyboard Tab Selection

**Files:**
- Modify: `main.swift:1274-1325` (switchToTab — add scroll-to-visible)
- Modify: `main.swift:1334-1390` (refreshTabBar — hook scroll on rebuild)

This task ensures that when a tab is selected via keyboard (Ctrl+Tab MRU, ⌘1-9), the tab bar auto-scrolls to bring it into view.

- [ ] **Step 1: Add auto-scroll to switchToTab**

At the end of `switchToTab(_:)`, after the existing setup, add:

```swift
// Auto-scroll tab bar to reveal the selected tab
if let tabItem = tabStack.arrangedSubviews.first(where: {
    ($0 as? TabBarItem)?.index == tabManager.currentIndex
}) as? TabBarItem {
    tabStack.scrollRectToVisible(tabItem.frame)
}
```

- [ ] **Step 2: Ensure scroll on refreshTabBar rebuild**

In `refreshTabBar()`, after rebuilding the tab stack, scroll to the current tab:

```swift
// At the end of refreshTabBar(), after updateURLField():
if let selectedItem = tabStack.arrangedSubviews.first(where: {
    ($0 as? TabBarItem)?.index == tabManager.currentIndex
}) as? TabBarItem {
    tabStack.scrollRectToVisible(selectedItem.frame)
}
```

- [ ] **Step 3: Commit**

```bash
git add main.swift
git commit -m "tabs: auto-scroll tab bar on keyboard tab selection"
```

---

### Spec Coverage Check

- **§2.2 Pill tabs, 7pt radius, no overlap, 4pt gap** → Task 1 (cornerRadius = 7), Task 2 (spacing = 4)
- **§2.2 Active 30pt, inactive 28pt, bottom-aligned** → Task 2 (height constraint conditional on isSelected)
- **§2.2 Color-only active state, no font-weight** → Task 1 (removed semibold)
- **§2.3 Favicon→close swap (14×14, same frame)** → Task 1 (iconSize = 14, closeSize = 14, swap in updateAppearance)
- **§2.3 Loading spinner replaces favicon** → Already implemented; no change needed
- **§2.4 Overflow scroll at 100pt min-width** → Task 2 (NSScrollView, min width 100)
- **§2.4 "+" button pinned outside scroll** → Task 2 (tabAddButton added directly to tabBar)
- **§2.4 Auto-scroll on keyboard selection** → Task 4 (scrollRectToVisible)
- **§3.2 Nav buttons left-anchored outside pill** → Already implemented; verified
- **§3.3 URL pill 16pt radius, 560pt max** → Task 3
- **§3.3 Edit state border glow only** → Task 3 (controlTextDidBeginEditing/EndEditing)
- **§2.1 Bottom margin (2pt)** → Task 2 (edgeInsets bottom: 2)
- **§5 V1 exclusions** → No tasks for pinned tabs, drag reorder; correct

---

### Execution Handoff

Plan complete and saved. Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints

Which approach?
