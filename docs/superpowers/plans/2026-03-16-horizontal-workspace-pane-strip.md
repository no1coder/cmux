# Horizontal Workspace Pane Strip Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn each workspace into a left-to-right strip of sibling panes, where `Cmd+D` splits the focused pane to the right, `Cmd+Opt+N` opens a new sibling pane to the right at the default pane width, and `Cmd+T` still creates a new surface inside the focused pane. Both pane-creation actions should be available from menus and the command palette.

**Architecture:** Reuse the existing `paperCanvas` internals as the geometry engine, but constrain them to a single horizontal strip of sibling panes separated by a fixed gutter. Keep `paperCanvas` and `viewport` as internal implementation terms for now, while the product model becomes `workspace -> pane -> surface`; pane focus and viewport movement should snap to discrete pane targets instead of behaving like a freeform nested split tree.

**Tech Stack:** Swift, SwiftUI/AppKit, PaneKit/Bonsplit, cmux socket v2, CLI, XCTest, GitHub Actions E2E

---

## Assumptions

- This phase is horizontal-only at the top level. A workspace can contain multiple sibling panes laid out left-to-right, but not top-level vertical siblings.
- `Cmd+D` remains the primary pane creation shortcut and always means "split the focused pane right".
- `Cmd+Opt+N` is a separate "open pane right" shortcut that inserts a new sibling pane to the right without resizing unrelated siblings, following niri-style top-level behavior.
- `Cmd+Shift+D` is disabled or returns `not_supported` in this mode instead of creating a vertical top-level pane.
- `Cmd+T` still creates a new surface in the focused pane.
- Surfaces remain horizontal tabs inside a pane. There is no second nested split model inside a pane in this mode.
- `Open Pane Right` must be exposed in both the standard app menus and the command palette, with the same customizable shortcut hint shown everywhere.
- Internal code can keep using `paperCanvas` and `viewport` names for now. User-facing naming changes can land later if needed.

## File Structure

- Modify: `PaneKit/Sources/PaneKit/Internal/Models/PaperCanvasState.swift`
  - Constrain pane placement to a single horizontal strip.
  - Keep a stable gutter between panes.
  - Add pane-aligned anchor helpers for snapping/revealing the visible area.
- Modify: `PaneKit/Sources/PaneKit/Internal/Controllers/SplitViewController.swift`
  - Route paper-canvas split operations through the horizontal pane-strip rules.
  - Reject unsupported top-level vertical splits in this mode.
  - Keep focus + viewport snapping aligned to pane boundaries.
- Modify: `PaneKit/Sources/PaneKit/Public/BonsplitController.swift`
  - Expose any new pane-strip metadata helpers needed by `Workspace`.
- Modify: `PaneKit/Sources/PaneKit/Internal/Views/PaperCanvasViewContainer.swift`
  - Render pane gutters and make the top-level strip feel discrete instead of continuous.
- Modify: `Sources/Workspace.swift`
  - Treat the paper-canvas layout as the workspace's top-level pane strip.
  - Preserve `surface` semantics inside each pane.
  - Differentiate `splitPaneRight` from `openPaneRight` insertion semantics.
  - Remove assumptions that paper-canvas panes can be nested arbitrary split leaves.
- Modify: `Sources/TabManager.swift`
  - Keep workspace-level commands (`movePaneFocus`, `newSurface`, `toggleFocusedSplitZoom`, `openPaneRight`) consistent with the pane-strip model.
- Modify: `Sources/AppDelegate.swift`
  - Keep keyboard routing aligned with the new pane-strip semantics.
  - Route `Cmd+Opt+N` to the new open-pane action.
  - Block unsupported vertical top-level split shortcuts in this mode.
- Modify: `Sources/KeyboardShortcutSettings.swift`
  - Add a customizable `openPaneRight` action with default `Cmd+Opt+N`.
  - Keep `Cmd+T` as new surface.
  - Preserve or trim pane-navigation shortcuts to match the horizontal-only first phase.
- Modify: `Sources/cmuxApp.swift`
  - Update menu text, enablement, and shortcut presentation for top-level pane operations.
  - Add `Open Pane Right` to the appropriate app menu alongside `Split Right`.
- Modify: `Sources/ContentView.swift`
  - Add command palette contributions, handlers, and shortcut hint mapping for `Open Pane Right`.
  - Keep `Split Right` and `Open Pane Right` distinct in command titles and keywords.
- Modify: `Sources/TerminalController.swift`
  - Return explicit API errors for unsupported vertical pane-strip operations.
  - Keep viewport pan / pane list payloads coherent with the new pane model.
- Modify: `CLI/cmux.swift`
  - Update help and any split-related error paths to reflect the horizontal-only pane strip.
- Test: `PaneKit/Tests/PaneKitTests/BonsplitTests.swift`
  - Geometry, ordering, gutter, unsupported-down-split, viewport anchor behavior.
- Test: `cmuxTests/WorkspacePaperCanvasTests.swift`
  - Workspace-level surface retention, restore, and pane-strip integration.
- Test: `cmuxTests/AppDelegateShortcutRoutingTests.swift`
  - Keyboard shortcuts, open-pane routing, and vertical-split rejection behavior.
- Test: `cmuxTests/CommandPaletteSearchEngineTests.swift`
  - Command palette discoverability and shortcut-hint wiring for split/open pane actions.
- Optional later: `cmuxUITests/`
  - Add CI-only UI coverage once the interaction model settles.
- Modify: `README.md`
  - Update shortcut table and pane/surface terminology once behavior is stable.

## Chunk 1: Pane Strip Geometry Contract

### Task 1: Lock the one-row pane-strip rules in PaneKit tests without changing split semantics

**Files:**
- Modify: `PaneKit/Tests/PaneKitTests/BonsplitTests.swift`

- [ ] **Step 1: Write the failing geometry tests**

```swift
func testPaperCanvasSplitRightKeepsLocalSplitBehaviorInSingleRow() {
    let controller = BonsplitController(configuration: BonsplitConfiguration(layoutStyle: .paperCanvas))
    let originalPane = controller.allPaneIds[0]
    let originalFrameBefore = controller.paperCanvasLayout()!.panes.first!.frame

    controller.splitPane(originalPane, direction: .right)

    guard let layout = controller.paperCanvasLayout() else {
        XCTFail("Expected paper canvas layout")
        return
    }

    XCTAssertEqual(layout.panes.count, 2)
    XCTAssertEqual(Set(layout.panes.map { $0.frame.minY }), [0])
    XCTAssertLessThan(layout.panes[0].frame.width, originalFrameBefore.width)
    XCTAssertEqual(layout.panes[0].frame.maxX + 16, layout.panes[1].frame.minX, accuracy: 0.001)
}

func testPaperCanvasSplitDownIsRejectedInHorizontalPaneStripMode() {
    let controller = BonsplitController(configuration: BonsplitConfiguration(layoutStyle: .paperCanvas))
    let originalPane = controller.allPaneIds[0]

    controller.splitPane(originalPane, direction: .down)

    guard let layout = controller.paperCanvasLayout() else {
        XCTFail("Expected paper canvas layout")
        return
    }

    XCTAssertEqual(layout.panes.count, 1)
}
```

- [ ] **Step 2: Run the targeted tests to verify they fail**

Run: `cd PaneKit && swift test --filter 'BonsplitTests/(testPaperCanvasSplitRightKeepsLocalSplitBehaviorInSingleRow|testPaperCanvasSplitDownIsRejectedInHorizontalPaneStripMode)'`

Expected: FAIL because paper-canvas still allows vertical top-level splits.

- [ ] **Step 3: Add the minimal one-row placement helpers**

```swift
extension PaperCanvasState {
    func supportsTopLevelSplit(_ orientation: SplitOrientation) -> Bool {
        orientation == .horizontal
    }
}
```

- [ ] **Step 4: Run the targeted tests again**

Run: `cd PaneKit && swift test --filter 'BonsplitTests/(testPaperCanvasSplitRightKeepsLocalSplitBehaviorInSingleRow|testPaperCanvasSplitDownIsRejectedInHorizontalPaneStripMode)'`

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add PaneKit/Tests/PaneKitTests/BonsplitTests.swift \
        PaneKit/Sources/PaneKit/Internal/Models/PaperCanvasState.swift \
        PaneKit/Sources/PaneKit/Internal/Controllers/SplitViewController.swift
git commit -m "feat: constrain paper canvas to horizontal pane strip"
```

### Task 1B: Add non-reflow `Open Pane Right` insertion to PaneKit

**Files:**
- Modify: `PaneKit/Tests/PaneKitTests/BonsplitTests.swift`
- Modify: `PaneKit/Sources/PaneKit/Internal/Models/PaperCanvasState.swift`
- Modify: `PaneKit/Sources/PaneKit/Internal/Controllers/SplitViewController.swift`
- Modify: `PaneKit/Sources/PaneKit/Public/BonsplitController.swift`

- [ ] **Step 1: Write the failing open-pane test**

```swift
func testPaperCanvasOpenPaneRightInsertsViewportSizedSiblingWithoutShrinkingCurrentPane() {
    let controller = BonsplitController(configuration: BonsplitConfiguration(layoutStyle: .paperCanvas))
    controller.setContainerFrame(CGRect(x: 0, y: 0, width: 1200, height: 800))

    let originalPane = controller.allPaneIds[0]
    let originalFrameBefore = controller.paperCanvasLayout()!.panes.first!.frame

    let newPane = controller.openPaperCanvasPaneRight(originalPane)
    let layout = controller.paperCanvasLayout()!

    XCTAssertNotNil(newPane)
    XCTAssertEqual(layout.panes.count, 2)
    XCTAssertEqual(layout.panes.first(where: { $0.paneId == originalPane })!.frame.width, originalFrameBefore.width, accuracy: 0.001)
    XCTAssertEqual(layout.panes.first(where: { $0.paneId == newPane })!.frame.width, 800, accuracy: 1.0)
    XCTAssertEqual(layout.viewportOrigin.x, 800, accuracy: 1.0)
}
```

- [ ] **Step 2: Run the targeted test to verify it fails**

Run: `cd PaneKit && swift test --filter testPaperCanvasOpenPaneRightInsertsViewportSizedSiblingWithoutShrinkingCurrentPane`

Expected: FAIL because paper-canvas has no distinct open-pane insertion path yet.

- [ ] **Step 3: Implement the non-reflow insertion helper**

```swift
extension PaperCanvasState {
    func openPaneRightPlacement(for targetFrame: CGRect, viewportSize: CGSize) -> CGRect {
        let width = floor(viewportSize.width * 0.66)
        return CGRect(x: targetFrame.maxX + paneGap, y: targetFrame.minY, width: width, height: targetFrame.height).integral
    }
}
```

- [ ] **Step 4: Re-run the targeted test**

Run: `cd PaneKit && swift test --filter testPaperCanvasOpenPaneRightInsertsViewportSizedSiblingWithoutShrinkingCurrentPane`

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add PaneKit/Tests/PaneKitTests/BonsplitTests.swift \
        PaneKit/Sources/PaneKit/Internal/Models/PaperCanvasState.swift \
        PaneKit/Sources/PaneKit/Internal/Controllers/SplitViewController.swift \
        PaneKit/Sources/PaneKit/Public/BonsplitController.swift
git commit -m "feat: add open pane right insertion for paper canvas"
```

### Task 2: Make viewport anchors pane-aligned instead of freeform

**Files:**
- Modify: `PaneKit/Tests/PaneKitTests/BonsplitTests.swift`
- Modify: `PaneKit/Sources/PaneKit/Internal/Models/PaperCanvasState.swift`
- Modify: `PaneKit/Sources/PaneKit/Internal/Controllers/SplitViewController.swift`

- [ ] **Step 1: Write the failing viewport anchor test**

```swift
func testPaperCanvasViewportSnapAnchorsMatchPaneOrigins() {
    let controller = BonsplitController(configuration: BonsplitConfiguration(layoutStyle: .paperCanvas))
    let first = controller.allPaneIds[0]

    controller.splitPane(first, direction: .right)
    controller.splitPane(first, direction: .right)

    guard let layout = controller.paperCanvasLayout() else {
        XCTFail("Expected paper canvas layout")
        return
    }

    let anchors = layout.panes.map(\.frame.minX)
    XCTAssertEqual(anchors, anchors.sorted())
    XCTAssertEqual(layout.viewportOrigin.x, anchors[0], accuracy: 0.001)
}
```

- [ ] **Step 2: Run the targeted test to verify it fails**

Run: `cd PaneKit && swift test --filter testPaperCanvasViewportSnapAnchorsMatchPaneOrigins`

Expected: FAIL because viewport movement is currently clamped but not modeled as pane-aligned anchors.

- [ ] **Step 3: Add pane-anchor helpers**

```swift
extension PaperCanvasState {
    var paneStripAnchors: [CGFloat] {
        panes.map { $0.frame.minX }.sorted()
    }

    func snapViewportToNearestPane() {
        guard let nearest = paneStripAnchors.min(by: { abs($0 - viewportOrigin.x) < abs($1 - viewportOrigin.x) }) else { return }
        viewportOrigin.x = nearest
        clampViewportOrigin()
    }
}
```

- [ ] **Step 4: Re-run the targeted test**

Run: `cd PaneKit && swift test --filter testPaperCanvasViewportSnapAnchorsMatchPaneOrigins`

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add PaneKit/Tests/PaneKitTests/BonsplitTests.swift \
        PaneKit/Sources/PaneKit/Internal/Models/PaperCanvasState.swift \
        PaneKit/Sources/PaneKit/Internal/Controllers/SplitViewController.swift
git commit -m "feat: add pane-aligned viewport anchors"
```

## Chunk 2: Workspace and Surface Semantics

### Task 3: Keep `surface` behavior intact inside each pane

**Files:**
- Modify: `cmuxTests/WorkspacePaperCanvasTests.swift`
- Modify: `Sources/Workspace.swift`
- Modify: `Sources/TabManager.swift`

- [ ] **Step 1: Write the failing workspace integration test**

```swift
func testWorkspaceSplitRightPreservesSurfaceTabsInSourcePane() {
    let workspace = makeWorkspace()

    workspace.newSurface()
    let originalPaneId = workspace.bonsplitController.focusedPaneId!

    workspace.split(.right)

    let panes = workspace.bonsplitController.allPaneIds
    XCTAssertEqual(panes.count, 2)
    XCTAssertEqual(workspace.bonsplitController.tabs(inPane: originalPaneId).count, 2)
}
```

- [ ] **Step 2: Run the targeted test to verify it fails**

Run: `xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux-unit -destination 'platform=macOS' -derivedDataPath /tmp/cmux-pane-strip-unit test -only-testing:cmuxTests/WorkspacePaperCanvasTests/testWorkspaceSplitRightPreservesSurfaceTabsInSourcePane`

Expected: FAIL because workspace-level split logic still assumes the old nested split model and does not explicitly protect the pane/surface boundary.

- [ ] **Step 3: Implement the minimal workspace routing**

```swift
func split(_ direction: SplitDirection) {
    guard direction == .right else { return }
    guard let paneId = bonsplitController.focusedPaneId else { return }
    bonsplitController.splitPane(paneId, direction: .right)
}
```

- [ ] **Step 4: Run the targeted test again**

Run: `xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux-unit -destination 'platform=macOS' -derivedDataPath /tmp/cmux-pane-strip-unit test -only-testing:cmuxTests/WorkspacePaperCanvasTests/testWorkspaceSplitRightPreservesSurfaceTabsInSourcePane`

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add cmuxTests/WorkspacePaperCanvasTests.swift \
        Sources/Workspace.swift \
        Sources/TabManager.swift
git commit -m "feat: preserve surface semantics inside pane strip"
```

### Task 4: Keep restore/persistence stable for ordered pane strips

**Files:**
- Modify: `cmuxTests/WorkspacePaperCanvasTests.swift`
- Modify: `Sources/Workspace.swift`
- Modify: `Sources/SessionPersistence.swift`

- [ ] **Step 1: Write the failing restore test**

```swift
func testWorkspaceRestoreKeepsHorizontalPaneOrderAndViewportAnchor() {
    let workspace = makeWorkspace()
    workspace.split(.right)
    workspace.split(.right)

    let snapshot = workspace.sessionLayoutSnapshot()
    let restored = restoreWorkspace(from: snapshot)
    let layout = restored.bonsplitController.paperCanvasLayout()!

    XCTAssertEqual(layout.panes.map { $0.frame.minX }, layout.panes.map { $0.frame.minX }.sorted())
    XCTAssertEqual(layout.viewportOrigin.x, layout.panes.first!.frame.minX, accuracy: 0.001)
}
```

- [ ] **Step 2: Run the targeted test to verify it fails**

Run: `xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux-unit -destination 'platform=macOS' -derivedDataPath /tmp/cmux-pane-strip-unit test -only-testing:cmuxTests/WorkspacePaperCanvasTests/testWorkspaceRestoreKeepsHorizontalPaneOrderAndViewportAnchor`

Expected: FAIL because existing restore is layout-general and does not normalize the new pane-strip invariants after decode.

- [ ] **Step 3: Normalize restore through the pane-strip contract**

```swift
func normalizeRestoredPaperCanvasStrip() {
    guard let layout = bonsplitController.paperCanvasLayout() else { return }
    let ordered = layout.panes.sorted { $0.frame.minX < $1.frame.minX }
    let normalizedOrigin = CGPoint(x: ordered.first?.frame.minX ?? 0, y: 0)
    _ = bonsplitController.setPaperCanvasViewportOrigin(normalizedOrigin, notify: false)
}
```

- [ ] **Step 4: Re-run the targeted test**

Run: `xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux-unit -destination 'platform=macOS' -derivedDataPath /tmp/cmux-pane-strip-unit test -only-testing:cmuxTests/WorkspacePaperCanvasTests/testWorkspaceRestoreKeepsHorizontalPaneOrderAndViewportAnchor`

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add cmuxTests/WorkspacePaperCanvasTests.swift \
        Sources/Workspace.swift \
        Sources/SessionPersistence.swift
git commit -m "feat: normalize pane strip restore state"
```

## Chunk 3: Shortcuts, Menus, Command Palette, and Visual Boundaries

### Task 5: Lock shortcut semantics before changing routing

**Files:**
- Modify: `cmuxTests/AppDelegateShortcutRoutingTests.swift`

- [ ] **Step 1: Write the failing shortcut tests**

```swift
func testCmdDAlwaysCreatesRightSiblingPaneInPaneStripMode() {
    let event = keyEvent("d", modifiers: [.command])
    XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
    XCTAssertEqual(splitDirections, [.right])
}

func testCmdShiftDIsRejectedInHorizontalPaneStripMode() {
    let event = keyEvent("d", modifiers: [.command, .shift])
    XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
    XCTAssertEqual(splitDirections, [])
}

func testCmdTRemainsNewSurfaceInFocusedPane() {
    let event = keyEvent("t", modifiers: [.command])
    XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
    XCTAssertEqual(newSurfaceCount, 1)
}

func testCmdOptNOpensRightSiblingPaneWithoutRoutingToSplit() {
    let event = keyEvent("n", modifiers: [.command, .option])
    XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
    XCTAssertEqual(openPaneRightCount, 1)
    XCTAssertEqual(splitDirections, [])
}
```

- [ ] **Step 2: Run the targeted tests to verify they fail**

Run: `xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux-unit -destination 'platform=macOS' -derivedDataPath /tmp/cmux-pane-strip-unit test -only-testing:cmuxTests/AppDelegateShortcutRoutingTests/testCmdDAlwaysCreatesRightSiblingPaneInPaneStripMode -only-testing:cmuxTests/AppDelegateShortcutRoutingTests/testCmdShiftDIsRejectedInHorizontalPaneStripMode -only-testing:cmuxTests/AppDelegateShortcutRoutingTests/testCmdTRemainsNewSurfaceInFocusedPane -only-testing:cmuxTests/AppDelegateShortcutRoutingTests/testCmdOptNOpensRightSiblingPaneWithoutRoutingToSplit`

Expected: FAIL because `Cmd+Shift+D` still routes to a down split and `Cmd+Opt+N` has not been introduced as a first-class pane-strip action.

- [ ] **Step 3: Implement the minimal routing changes**

```swift
if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .splitDown)) {
    if selectedWorkspace?.bonsplitController.layoutStyle == .paperCanvas {
        NSSound.beep()
        return true
    }
    _ = performSplitShortcut(direction: .down)
    return true
}

if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .openPaneRight)) {
    activeTabManager.openPaneRight()
    return true
}
```

- [ ] **Step 4: Re-run the targeted tests**

Run: `xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux-unit -destination 'platform=macOS' -derivedDataPath /tmp/cmux-pane-strip-unit test -only-testing:cmuxTests/AppDelegateShortcutRoutingTests/testCmdDAlwaysCreatesRightSiblingPaneInPaneStripMode -only-testing:cmuxTests/AppDelegateShortcutRoutingTests/testCmdShiftDIsRejectedInHorizontalPaneStripMode -only-testing:cmuxTests/AppDelegateShortcutRoutingTests/testCmdTRemainsNewSurfaceInFocusedPane -only-testing:cmuxTests/AppDelegateShortcutRoutingTests/testCmdOptNOpensRightSiblingPaneWithoutRoutingToSplit`

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add cmuxTests/AppDelegateShortcutRoutingTests.swift \
        Sources/AppDelegate.swift \
        Sources/KeyboardShortcutSettings.swift
git commit -m "feat: align split and open-pane shortcuts with horizontal pane strip"
```

### Task 5B: Expose split/open pane actions in menus and command palette

**Files:**
- Modify: `Sources/cmuxApp.swift`
- Modify: `Sources/ContentView.swift`
- Modify: `cmuxTests/CommandPaletteSearchEngineTests.swift`

- [ ] **Step 1: Write the failing command palette coverage**

```swift
func testCommandPaletteIndexesOpenPaneRightCommand() {
    let previewCommandIDs = ContentView.commandPaletteCommandPreviewMatchCommandIDsForTests(
        searchCorpus: makeCorpus(["palette.terminalSplitRight", "palette.terminalOpenPaneRight"]),
        candidateCommandIDs: ["palette.terminalOpenPaneRight"],
        searchCorpusByID: makeCorpusByID(["palette.terminalSplitRight", "palette.terminalOpenPaneRight"]),
        query: "open pane right",
        resultLimit: 48
    )

    XCTAssertEqual(previewCommandIDs.first, "palette.terminalOpenPaneRight")
}
```

- [ ] **Step 2: Run the targeted command palette test to verify it fails**

Run: `xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux-unit -destination 'platform=macOS' -derivedDataPath /tmp/cmux-pane-strip-unit test -only-testing:cmuxTests/CommandPaletteSearchEngineTests/testCommandPaletteIndexesOpenPaneRightCommand`

Expected: FAIL because the command palette does not yet expose a distinct open-pane action.

- [ ] **Step 3: Add the menu and command palette actions**

```swift
CommandPaletteCommandContribution(
    commandId: "palette.terminalOpenPaneRight",
    title: constant(String(localized: "command.terminalOpenPaneRight.title", defaultValue: "Open Pane Right")),
    subtitle: constant(String(localized: "command.terminalOpenPaneRight.subtitle", defaultValue: "Terminal Layout")),
    keywords: ["terminal", "open", "pane", "right", "new"],
    when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
)

registry.register(commandId: "palette.terminalOpenPaneRight") {
    tabManager.openPaneRight()
}
```

- [ ] **Step 4: Re-run the targeted command palette test and verify the menu wiring builds**

Run: `xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux-unit -destination 'platform=macOS' -derivedDataPath /tmp/cmux-pane-strip-unit test -only-testing:cmuxTests/CommandPaletteSearchEngineTests/testCommandPaletteIndexesOpenPaneRightCommand`

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/cmuxApp.swift \
        Sources/ContentView.swift \
        cmuxTests/CommandPaletteSearchEngineTests.swift
git commit -m "feat: expose open pane right in menus and command palette"
```

### Task 6: Make panes feel discrete in the paper-canvas view

**Files:**
- Modify: `PaneKit/Sources/PaneKit/Internal/Views/PaperCanvasViewContainer.swift`
- Modify: `PaneKit/Sources/PaneKit/Public/BonsplitView.swift`
- Modify: `Sources/cmuxApp.swift`

- [ ] **Step 1: Write a failing geometry assertion around gutter spacing**

```swift
func testPaperCanvasSplitRightMaintainsConfiguredPaneGap() {
    let controller = BonsplitController(configuration: BonsplitConfiguration(layoutStyle: .paperCanvas))
    let first = controller.allPaneIds[0]

    controller.splitPane(first, direction: .right)
    let layout = controller.paperCanvasLayout()!
    let gap = layout.panes[1].frame.minX - layout.panes[0].frame.maxX

    XCTAssertEqual(gap, 16, accuracy: 0.001)
}
```

- [ ] **Step 2: Run the targeted test to verify it fails**

Run: `cd PaneKit && swift test --filter testPaperCanvasSplitRightMaintainsConfiguredPaneGap`

Expected: FAIL if the top-level strip still reuses old local-reflow positioning or if the view rendering visually collapses pane separation.

- [ ] **Step 3: Implement the gutter polish**

```swift
ForEach(controller.paperCanvas?.panes ?? []) { placement in
    SinglePaneWrapper(...)
        .padding(.trailing, appearance.paneGap)
        .offset(x: placement.frame.minX - controller.paperViewportOrigin.x,
                y: placement.frame.minY - controller.paperViewportOrigin.y)
}
```

- [ ] **Step 4: Re-run the targeted test**

Run: `cd PaneKit && swift test --filter testPaperCanvasSplitRightMaintainsConfiguredPaneGap`

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add PaneKit/Tests/PaneKitTests/BonsplitTests.swift \
        PaneKit/Sources/PaneKit/Internal/Views/PaperCanvasViewContainer.swift \
        PaneKit/Sources/PaneKit/Public/BonsplitView.swift \
        Sources/cmuxApp.swift
git commit -m "feat: add discrete pane strip gutters"
```

## Chunk 4: Public API, CLI, and Docs

### Task 7: Make unsupported vertical operations explicit in socket and CLI

**Files:**
- Modify: `Sources/TerminalController.swift`
- Modify: `CLI/cmux.swift`

- [ ] **Step 1: Write the failing CLI/socket regression test**

```python
def test_new_split_down_returns_not_supported_for_horizontal_pane_strip():
    payload = send_v2("surface.split", {"workspace_id": "workspace:1", "direction": "down"})
    assert payload["error"]["code"] == "not_supported"
```

- [ ] **Step 2: Run the targeted regression check to verify it fails**

Run: `python3 Tests/test_ctrl_socket.py`

Expected: FAIL or no coverage, proving the unsupported-down path is not yet explicit.

- [ ] **Step 3: Implement the explicit error path**

```swift
guard direction != .down || ws.bonsplitController.layoutStyle != .paperCanvas else {
    return .err(code: "not_supported", message: "Vertical top-level pane splits are not supported in horizontal pane strip mode", data: nil)
}
```

- [ ] **Step 4: Re-run the regression check**

Run: `xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux-unit -destination 'platform=macOS' -derivedDataPath /tmp/cmux-pane-strip-unit build`

Expected: BUILD SUCCEEDED, and the dedicated regression test passes once added.

- [ ] **Step 5: Commit**

```bash
git add Sources/TerminalController.swift CLI/cmux.swift Tests/
git commit -m "feat: expose pane strip split limits in public APIs"
```

### Task 8: Update user-facing docs and CI coverage

**Files:**
- Modify: `README.md`
- Modify: `Sources/cmuxApp.swift`
- Optional Create: `cmuxUITests/HorizontalPaneStripUITests.swift`

- [ ] **Step 1: Update the shortcut and terminology docs**

```md
| ⌘ D | Split pane right |
| ⌘ ⌥ N | Open pane right |
| ⌘ ⇧ D | Not available in horizontal pane-strip mode |
| ⌘ T | New surface in focused pane |
```

- [ ] **Step 2: Add or update a CI-only UI smoke test**

```swift
func testSplitPaneRightCreatesSecondTopLevelPane() {
    XCUIKeyboardKey("d").withModifiers(.command).tap()
    XCTAssertEqual(app.otherElements.matching(identifier: "workspace-pane").count, 2)
}
```

- [ ] **Step 3: Trigger the relevant E2E workflow**

Run:

```bash
gh workflow run test-e2e.yml --repo manaflow-ai/cmux \
  -f ref=issue-1221-paper-window-manager-layout \
  -f test_filter="HorizontalPaneStripUITests" \
  -f record_video=true
```

Expected: workflow queued successfully

- [ ] **Step 4: Watch the workflow to green**

Run: `gh run watch --repo manaflow-ai/cmux <run-id>`

Expected: completed with success

- [ ] **Step 5: Commit**

```bash
git add README.md cmuxUITests/ Sources/cmuxApp.swift
git commit -m "docs: describe horizontal pane strip shortcuts"
```

## Notes for Execution

- Prefer reusing `paperCanvas` internals over inventing a second top-level layout engine.
- Do not rename every internal `pane`/`paperCanvas` symbol up front. Get the behavior stable first.
- Treat `Cmd+Shift+D` and vertical top-level operations as explicit non-goals in this phase.
- Keep `Cmd+T`, surface switching, and close-surface behavior untouched unless a failing test proves a conflict.
- After each chunk, if the plan-review subagent is available in the harness, run it before starting the next chunk.

Plan complete and saved to `docs/superpowers/plans/2026-03-16-horizontal-workspace-pane-strip.md`. Ready to execute?
