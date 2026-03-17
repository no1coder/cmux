# Horizontal Pane Strip Stabilization Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the current frame-first paper-canvas behavior with a deterministic horizontal pane-strip model so the initial pane fills the viewport, `Split Right` and `Open Pane Right` behave predictably, focus/reveal stops feeling janky, and the app still preserves cmux surface tabs inside each pane.

**Architecture:** Keep `paperCanvas` as the public/internal compatibility surface for now, but make horizontal mode derive its frames from a semantic 1D strip state instead of using `CGRect` collision logic as the source of truth. The new strip state should own ordered panes, widths, and viewport anchor state; `PaperCanvasLayoutSnapshot` stays available as a derived snapshot so `Workspace`, restore, CLI, and tests do not need a simultaneous rewrite.

**Tech Stack:** Swift, SwiftUI/AppKit, PaneKit, XCTest, XCUITest, GitHub Actions

---

This plan supersedes `docs/superpowers/plans/2026-03-16-horizontal-workspace-pane-strip.md` for geometry, controller, and feel work. Keep the earlier plan only as historical context for command/menu wiring that already landed.

## Scope

- Fix the source of the jank in horizontal pane-strip mode.
- Do not redesign shortcuts, menus, command palette, CLI, or socket names unless the refactor forces a signature change.
- Do not add top-level vertical pane strips in this pass.
- Do not rename public `paperCanvas` APIs yet.
- Keep the session wire format backward compatible if possible. Prefer inferring strip state from existing saved frames over changing restore data structures.

## File Structure

- Create: `PaneKit/Sources/PaneKit/Internal/Models/PaperCanvasStripState.swift`
  - Semantic 1D source of truth for horizontal paper-canvas mode.
  - Own pane order, pane widths, viewport width/height, gutter, and reveal anchors.
  - No collision detection. No stored freeform Y offsets.
- Modify: `PaneKit/Sources/PaneKit/Internal/Models/PaperCanvasState.swift`
  - Turn this into a compatibility facade over `PaperCanvasStripState`.
  - Keep `PaperCanvasLayoutSnapshot`, `PaperCanvasPane`, and derived frames for existing call sites.
- Modify: `PaneKit/Sources/PaneKit/Internal/Controllers/SplitViewController.swift`
  - Route split/open/close/resize/focus/equalize/reveal through strip-state primitives.
  - Remove frame-first placement decisions from horizontal mode.
- Modify: `PaneKit/Sources/PaneKit/Public/BonsplitController.swift`
  - Preserve the current public API surface while delegating to the new strip behavior.
- Modify: `PaneKit/Sources/PaneKit/Internal/Views/PaperCanvasViewContainer.swift`
  - Animate the presented viewport X as a single scalar.
  - Render overflow affordances without adding permanent chrome.
- Modify: `PaneKit/Sources/PaneKit/Internal/Styling/TabBarMetrics.swift`
  - Add any strip-specific timing constants in one place if needed.
- Create: `PaneKit/Tests/PaneKitTests/PaperCanvasStripStateTests.swift`
  - Pure model tests for widths, ordering, reveal anchors, equalize, close, and overflow hint state.
- Modify: `PaneKit/Tests/PaneKitTests/BonsplitTests.swift`
  - Integration tests proving `BonsplitController` still exposes the expected behavior and snapshots.
- Modify: `Sources/Workspace.swift`
  - Keep workspace panel/surface mappings coherent with ordered top-level panes.
  - Restore strip state from existing saved canvas snapshots.
- Modify: `Sources/SessionPersistence.swift`
  - Only if required to add derived restore helpers. Avoid schema changes unless impossible.
- Modify: `cmuxTests/WorkspacePaperCanvasTests.swift`
  - Workspace-level behavior for open/split/close/restore.
- Create: `cmuxUITests/PaneStripUITests.swift`
  - CI-only behavioral coverage for first-pane fill, split, open-pane-right reveal, and rejected vertical split.

Files that should not change unless the refactor forces them:

- `Sources/AppDelegate.swift`
- `Sources/ContentView.swift`
- `Sources/cmuxApp.swift`
- `Sources/TerminalController.swift`
- `CLI/cmux.swift`

Those routes already exist and are not the source of the current jank.

## Chunk 1: Replace Frame-First Geometry With a Strip Model

### Task 1: Create a pure strip-state test harness first

**Files:**
- Create: `PaneKit/Tests/PaneKitTests/PaperCanvasStripStateTests.swift`

- [ ] **Step 1: Write the failing pure-model tests**

```swift
import XCTest
@testable import PaneKit

@MainActor
final class PaperCanvasStripStateTests: XCTestCase {
    func testBootstrapSinglePaneMatchesViewportSize() {
        let paneId = PaneID()
        let state = PaperCanvasStripState(
            items: [.init(paneId: paneId, width: 960)],
            viewportSize: CGSize(width: 1400, height: 900),
            viewportOriginX: 0,
            paneGap: 16
        )

        let frames = state.framesByPaneId()
        XCTAssertEqual(frames[paneId]?.width, 1400, accuracy: 1.0)
        XCTAssertEqual(frames[paneId]?.height, 900, accuracy: 1.0)
    }

    func testSplitRightHalvesCurrentPaneInsideItsExistingFootprint() {
        let left = PaneID()
        var state = PaperCanvasStripState.bootstrap(
            paneId: left,
            viewportSize: CGSize(width: 1200, height: 800),
            paneGap: 16
        )

        let right = state.splitRight(left, minimumPaneWidth: 260)
        let frames = state.framesByPaneId()

        XCTAssertNotNil(right)
        XCTAssertEqual(frames[left]!.maxX + 16, frames[right!]!.minX, accuracy: 1.0)
        XCTAssertEqual(frames[left]!.width, frames[right!]!.width, accuracy: 1.0)
        XCTAssertEqual(frames[left]!.maxX, 592, accuracy: 2.0)
    }

    func testOpenPaneRightPreservesExistingWidthsAndUsesTwoThirdsViewportWidth() {
        let left = PaneID()
        var state = PaperCanvasStripState.bootstrap(
            paneId: left,
            viewportSize: CGSize(width: 1200, height: 800),
            paneGap: 16
        )

        let inserted = state.openPaneRight(after: left, requestedWidth: 800, minimumPaneWidth: 260)
        let frames = state.framesByPaneId()

        XCTAssertEqual(frames[left]!.width, 1200, accuracy: 1.0)
        XCTAssertEqual(frames[inserted]!.width, 800, accuracy: 1.0)
        XCTAssertEqual(state.viewportOriginX, 816, accuracy: 1.0)
    }

    func testClosePrefersNearestLeftNeighborForFocus() {
        let first = PaneID()
        var state = PaperCanvasStripState.bootstrap(
            paneId: first,
            viewportSize: CGSize(width: 1200, height: 800),
            paneGap: 16
        )
        let second = state.openPaneRight(after: first, requestedWidth: 800, minimumPaneWidth: 260)
        let third = state.openPaneRight(after: second, requestedWidth: 800, minimumPaneWidth: 260)

        let nextFocus = state.closePane(second, preferredFocus: second)

        XCTAssertEqual(nextFocus, first)
        XCTAssertEqual(state.items.map(\.paneId), [first, third])
    }
}
```

- [ ] **Step 2: Run the new test file and confirm it fails**

Run: `cd PaneKit && swift test --filter PaperCanvasStripStateTests`

Expected: FAIL with compiler errors because `PaperCanvasStripState` does not exist yet.

- [ ] **Step 3: Create the minimal strip model**

```swift
import CoreGraphics
import Foundation

struct PaperCanvasStripItem: Equatable, Sendable {
    let paneId: PaneID
    var width: CGFloat
}

struct PaperCanvasStripState: Equatable, Sendable {
    var items: [PaperCanvasStripItem]
    var viewportSize: CGSize
    var viewportOriginX: CGFloat
    let paneGap: CGFloat

    static func bootstrap(paneId: PaneID, viewportSize: CGSize, paneGap: CGFloat) -> Self {
        Self(
            items: [.init(paneId: paneId, width: viewportSize.width)],
            viewportSize: viewportSize,
            viewportOriginX: 0,
            paneGap: paneGap
        )
    }

    func framesByPaneId() -> [PaneID: CGRect] {
        var nextX: CGFloat = 0
        var result: [PaneID: CGRect] = [:]
        for item in items {
            result[item.paneId] = CGRect(
                x: nextX,
                y: 0,
                width: item.width,
                height: viewportSize.height
            ).integral
            nextX += item.width + paneGap
        }
        return result
    }
}
```

- [ ] **Step 4: Run the pure-model tests again**

Run: `cd PaneKit && swift test --filter PaperCanvasStripStateTests`

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add PaneKit/Sources/PaneKit/Internal/Models/PaperCanvasStripState.swift \
        PaneKit/Tests/PaneKitTests/PaperCanvasStripStateTests.swift
git commit -m "refactor: add paper canvas strip state model"
```

### Task 2: Make `PaperCanvasState` a compatibility facade over the strip state

**Files:**
- Modify: `PaneKit/Sources/PaneKit/Internal/Models/PaperCanvasState.swift`
- Modify: `PaneKit/Tests/PaneKitTests/BonsplitTests.swift`

- [ ] **Step 1: Write the failing integration tests against existing public behavior**

```swift
@MainActor
func testPaperCanvasLayoutSnapshotIsDerivedFromStripState() {
    let controller = BonsplitController(
        configuration: BonsplitConfiguration(layoutStyle: .paperCanvas)
    )
    controller.setContainerFrame(CGRect(x: 0, y: 0, width: 1400, height: 900))

    guard let root = controller.focusedPaneId else {
        return XCTFail("Expected focused pane")
    }
    let inserted = controller.openPaperCanvasPaneRight(root)!
    let layout = controller.paperCanvasLayout()!

    XCTAssertEqual(layout.panes.map(\.frame.minY), [0, 0])
    XCTAssertEqual(layout.panes.first(where: { $0.paneId == root })!.frame.width, 1400, accuracy: 1.0)
    XCTAssertEqual(layout.panes.first(where: { $0.paneId == inserted })!.frame.width, 933, accuracy: 1.0)
}

@MainActor
func testApplyPaperCanvasLayoutRestoresOrderedStripWidthsFromFrames() {
    let controller = BonsplitController(
        configuration: BonsplitConfiguration(layoutStyle: .paperCanvas)
    )
    controller.setContainerFrame(CGRect(x: 0, y: 0, width: 1200, height: 800))

    let first = controller.focusedPaneId!
    let second = controller.openPaperCanvasPaneRight(first)!

    let snapshot = PaperCanvasLayoutSnapshot(
        panes: [
            .init(paneId: first, frame: CGRect(x: 0, y: 0, width: 600, height: 800)),
            .init(paneId: second, frame: CGRect(x: 616, y: 0, width: 800, height: 800)),
        ],
        viewportOrigin: CGPoint(x: 216, y: 0),
        focusedPaneId: second
    )

    XCTAssertTrue(controller.applyPaperCanvasLayout(snapshot))
    let restored = controller.paperCanvasLayout()!
    XCTAssertEqual(restored.panes.map(\.frame.minX), [0, 616], accuracy: 1.0)
    XCTAssertEqual(restored.viewportOrigin.x, 216, accuracy: 1.0)
}
```

- [ ] **Step 2: Run the targeted integration tests and confirm failure**

Run: `cd PaneKit && swift test --filter 'BonsplitTests/(testPaperCanvasLayoutSnapshotIsDerivedFromStripState|testApplyPaperCanvasLayoutRestoresOrderedStripWidthsFromFrames)'`

Expected: FAIL because `PaperCanvasState` still treats frames as primary state.

- [ ] **Step 3: Refactor `PaperCanvasState` to derive frames from strip state**

```swift
@Observable
final class PaperCanvasState {
    var panes: [PaperCanvasPane]
    var stripState: PaperCanvasStripState

    func syncPlacementsFromStrip() {
        let frames = stripState.framesByPaneId()
        for placement in panes {
            placement.frame = frames[placement.pane.id] ?? .zero
        }
        viewportOrigin = CGPoint(x: stripState.viewportOriginX, y: 0)
        viewportSize = stripState.viewportSize
        recomputeCanvasBounds()
    }

    func addPane(_ pane: PaneState, after targetPaneId: PaneID, requestedWidth: CGFloat) {
        let insertedPaneId = stripState.openPaneRight(after: targetPaneId, requestedWidth: requestedWidth, minimumPaneWidth: 260)
        panes.append(PaperCanvasPane(pane: pane, frame: .zero))
        syncPlacementsFromStrip()
    }
}
```

- [ ] **Step 4: Run the targeted integration tests again**

Run: `cd PaneKit && swift test --filter 'BonsplitTests/(testPaperCanvasLayoutSnapshotIsDerivedFromStripState|testApplyPaperCanvasLayoutRestoresOrderedStripWidthsFromFrames)'`

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add PaneKit/Sources/PaneKit/Internal/Models/PaperCanvasState.swift \
        PaneKit/Tests/PaneKitTests/BonsplitTests.swift
git commit -m "refactor: derive paper canvas frames from strip state"
```

## Chunk 2: Route Controller Behavior Through Strip Primitives

### Task 3: Move split, open, close, resize, and equalize into strip-state operations

**Files:**
- Modify: `PaneKit/Sources/PaneKit/Internal/Controllers/SplitViewController.swift`
- Modify: `PaneKit/Sources/PaneKit/Public/BonsplitController.swift`
- Modify: `PaneKit/Tests/PaneKitTests/BonsplitTests.swift`

- [ ] **Step 1: Write the failing controller-integration tests**

```swift
@MainActor
func testPaperCanvasCloseUsesStripNeighborFocusRules() {
    let controller = BonsplitController(
        configuration: BonsplitConfiguration(layoutStyle: .paperCanvas)
    )
    controller.setContainerFrame(CGRect(x: 0, y: 0, width: 1200, height: 800))

    let first = controller.focusedPaneId!
    let second = controller.openPaperCanvasPaneRight(first)!
    let third = controller.openPaperCanvasPaneRight(second)!

    controller.focusPane(second)
    XCTAssertTrue(controller.closePane(second))

    XCTAssertEqual(controller.focusedPaneId, first)
    XCTAssertEqual(controller.allPaneIds, [first, third])
}

@MainActor
func testPaperCanvasEqualizeUsesStripOrderRatherThanLegacySplitTree() {
    let controller = BonsplitController(
        configuration: BonsplitConfiguration(layoutStyle: .paperCanvas)
    )
    controller.setContainerFrame(CGRect(x: 0, y: 0, width: 1200, height: 800))

    let first = controller.focusedPaneId!
    let second = controller.openPaperCanvasPaneRight(first)!
    XCTAssertTrue(controller.resizePaperPane(first, direction: .right, amount: 160))

    XCTAssertTrue(controller.equalizePaperPanes())
    let layout = controller.paperCanvasLayout()!

    XCTAssertEqual(layout.panes.first(where: { $0.paneId == first })!.frame.width,
                   layout.panes.first(where: { $0.paneId == second })!.frame.width,
                   accuracy: 1.0)
}
```

- [ ] **Step 2: Run the targeted controller tests and confirm failure**

Run: `cd PaneKit && swift test --filter 'BonsplitTests/(testPaperCanvasCloseUsesStripNeighborFocusRules|testPaperCanvasEqualizeUsesStripOrderRatherThanLegacySplitTree)'`

Expected: FAIL because the controller still mixes strip behavior with frame-first logic.

- [ ] **Step 3: Refactor the controller and public wrappers**

```swift
@discardableResult
func openPaperCanvasPaneRight(_ paneId: PaneID, newTab: TabItem? = nil) -> PaneID? {
    guard let paperCanvas else { return nil }
    let requestedWidth = floor(paperCanvas.viewportSize.width * (2.0 / 3.0))
    let newPaneId = paperCanvas.insertPaneRight(of: paneId, newTab: newTab, requestedWidth: requestedWidth)
    focusedPaneId = newPaneId
    return newPaneId
}

func focusPane(_ paneId: PaneID) {
    focusedPaneId = paneId
    paperCanvas?.revealPane(paneId)
}

func equalizePaperPanes() -> Bool {
    paperCanvas?.equalizeStripWidths(minimumWidth: minimumPaneWidth) ?? false
}
```

- [ ] **Step 4: Re-run the targeted controller tests**

Run: `cd PaneKit && swift test --filter 'BonsplitTests/(testPaperCanvasCloseUsesStripNeighborFocusRules|testPaperCanvasEqualizeUsesStripOrderRatherThanLegacySplitTree)'`

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add PaneKit/Sources/PaneKit/Internal/Controllers/SplitViewController.swift \
        PaneKit/Sources/PaneKit/Public/BonsplitController.swift \
        PaneKit/Tests/PaneKitTests/BonsplitTests.swift
git commit -m "refactor: route paper canvas controller through strip operations"
```

### Task 4: Keep workspace, restore, and panel mapping stable

**Files:**
- Modify: `Sources/Workspace.swift`
- Modify: `Sources/SessionPersistence.swift`
- Modify: `cmuxTests/WorkspacePaperCanvasTests.swift`

- [ ] **Step 1: Write the failing workspace tests**

```swift
func testWorkspaceOpenPaneRightPreservesSurfaceTabsAndFocusesInsertedPane() {
    let workspace = makeWorkspace()
    _ = workspace.newTerminalSurfaceInFocusedPane()

    let sourcePanelId = try XCTUnwrap(workspace.focusedPanelId)
    let sourcePaneId = try XCTUnwrap(workspace.paneId(forPanelId: sourcePanelId))

    let insertedPanel = workspace.openTerminalPaneRight(from: sourcePanelId)
    let layout = try XCTUnwrap(workspace.bonsplitController.paperCanvasLayout())

    XCTAssertNotNil(insertedPanel)
    XCTAssertEqual(workspace.bonsplitController.tabs(inPane: sourcePaneId).count, 2)
    XCTAssertEqual(layout.focusedPaneId, workspace.paneId(forPanelId: insertedPanel!.id))
}

func testWorkspaceRestoresCanvasSnapshotIntoOrderedStripWithoutSchemaChange() {
    let workspace = makeWorkspace()
    let sourcePanelId = try XCTUnwrap(workspace.focusedPanelId)
    let inserted = try XCTUnwrap(workspace.openTerminalPaneRight(from: sourcePanelId))

    let snapshot = workspace.debugSessionSnapshot()
    let restored = restoreWorkspace(from: snapshot)
    let layout = try XCTUnwrap(restored.bonsplitController.paperCanvasLayout())

    XCTAssertEqual(layout.panes.map(\.frame.minX), layout.panes.map(\.frame.minX).sorted())
    XCTAssertEqual(restored.focusedPanelId, inserted.id)
}
```

- [ ] **Step 2: Run the targeted workspace tests and confirm failure**

Run: `xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux-unit -destination 'platform=macOS' -derivedDataPath /tmp/cmux-pane-strip-stability test -only-testing:cmuxTests/WorkspacePaperCanvasTests/testWorkspaceOpenPaneRightPreservesSurfaceTabsAndFocusesInsertedPane -only-testing:cmuxTests/WorkspacePaperCanvasTests/testWorkspaceRestoresCanvasSnapshotIntoOrderedStripWithoutSchemaChange`

Expected: FAIL because `Workspace` restore/open logic still assumes frame snapshots are primary state.

- [ ] **Step 3: Implement the minimal workspace bridge**

```swift
private func applySessionLayoutGeometry(
    _ snapshotLayout: SessionWorkspaceLayoutSnapshot,
    livePanes: [PaneID]
) {
    guard case .canvas(let canvas) = snapshotLayout else { return }

    let layout = PaperCanvasLayoutSnapshot(
        panes: zip(livePanes, canvas.panes).map { pair in
            .init(paneId: pair.0, frame: pair.1.frame.cgRect)
        },
        viewportOrigin: canvas.viewportOrigin?.cgPoint ?? .zero,
        focusedPaneId: canvas.focusedPaneIndex.flatMap { livePanes.indices.contains($0) ? livePanes[$0] : nil }
    )
    _ = bonsplitController.applyPaperCanvasLayout(layout, notify: false)
}
```

- [ ] **Step 4: Re-run the targeted workspace tests**

Run: `xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux-unit -destination 'platform=macOS' -derivedDataPath /tmp/cmux-pane-strip-stability test -only-testing:cmuxTests/WorkspacePaperCanvasTests/testWorkspaceOpenPaneRightPreservesSurfaceTabsAndFocusesInsertedPane -only-testing:cmuxTests/WorkspacePaperCanvasTests/testWorkspaceRestoresCanvasSnapshotIntoOrderedStripWithoutSchemaChange`

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/Workspace.swift \
        Sources/SessionPersistence.swift \
        cmuxTests/WorkspacePaperCanvasTests.swift
git commit -m "fix: keep workspace paper canvas restore compatible with strip state"
```

## Chunk 3: Make It Feel Good

### Task 5: Animate only the viewport X and add subtle overflow affordances

**Files:**
- Modify: `PaneKit/Sources/PaneKit/Internal/Views/PaperCanvasViewContainer.swift`
- Modify: `PaneKit/Sources/PaneKit/Internal/Styling/TabBarMetrics.swift`
- Modify: `PaneKit/Tests/PaneKitTests/PaperCanvasStripStateTests.swift`

- [ ] **Step 1: Write the failing model tests for reveal anchors and overflow hint state**

```swift
func testRevealPaneSnapsViewportToPaneAnchor() {
    let first = PaneID()
    var state = PaperCanvasStripState.bootstrap(
        paneId: first,
        viewportSize: CGSize(width: 1200, height: 800),
        paneGap: 16
    )
    let second = state.openPaneRight(after: first, requestedWidth: 800, minimumPaneWidth: 260)

    state.revealPane(second)

    XCTAssertEqual(state.viewportOriginX, 816, accuracy: 1.0)
}

func testOverflowHintsReflectHiddenNeighbors() {
    let first = PaneID()
    var state = PaperCanvasStripState.bootstrap(
        paneId: first,
        viewportSize: CGSize(width: 1200, height: 800),
        paneGap: 16
    )
    let second = state.openPaneRight(after: first, requestedWidth: 800, minimumPaneWidth: 260)
    state.revealPane(second)

    XCTAssertTrue(state.showsLeftOverflowHint)
    XCTAssertFalse(state.showsRightOverflowHint)
}
```

- [ ] **Step 2: Run the model tests and confirm failure**

Run: `cd PaneKit && swift test --filter 'PaperCanvasStripStateTests/(testRevealPaneSnapsViewportToPaneAnchor|testOverflowHintsReflectHiddenNeighbors)'`

Expected: FAIL because reveal anchors and overflow hints are not encoded in strip state yet.

- [ ] **Step 3: Implement reveal helpers and animate only one scalar in the view**

```swift
extension PaperCanvasStripState {
    mutating func revealPane(_ paneId: PaneID) {
        guard let frame = framesByPaneId()[paneId] else { return }
        viewportOriginX = max(0, min(frame.maxX - viewportSize.width, frame.minX))
    }

    var showsLeftOverflowHint: Bool { viewportOriginX > 0 }
    var showsRightOverflowHint: Bool { totalContentWidth > viewportOriginX + viewportSize.width }
}

struct PaperCanvasViewContainer<Content: View, EmptyContent: View>: View {
    @State private var displayedViewportOriginX: CGFloat = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            paneStack
                .offset(x: -displayedViewportOriginX)
                .animation(.snappy(duration: TabBarMetrics.splitAnimationDuration), value: displayedViewportOriginX)

            if controller.paperCanvasShowsLeftOverflowHint { leftHint }
            if controller.paperCanvasShowsRightOverflowHint { rightHint }
        }
    }
}
```

- [ ] **Step 4: Re-run the model tests**

Run: `cd PaneKit && swift test --filter 'PaperCanvasStripStateTests/(testRevealPaneSnapsViewportToPaneAnchor|testOverflowHintsReflectHiddenNeighbors)'`

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add PaneKit/Sources/PaneKit/Internal/Views/PaperCanvasViewContainer.swift \
        PaneKit/Sources/PaneKit/Internal/Styling/TabBarMetrics.swift \
        PaneKit/Tests/PaneKitTests/PaperCanvasStripStateTests.swift
git commit -m "feat: add strip reveal anchors and overflow affordances"
```

### Task 6: Add UI smoke coverage for the critical feel regressions

**Files:**
- Create: `cmuxUITests/PaneStripUITests.swift`

- [ ] **Step 1: Write the UI smoke test**

```swift
import XCTest

final class PaneStripUITests: XCTestCase {
    func testInitialPaneFillSplitAndOpenPaneRight() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_PANE_STRIP"] = "1"
        app.launch()

        let rootPane = app.otherElements["pane.0"]
        XCTAssertTrue(rootPane.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(rootPane.frame.width, 1000)

        app.typeKey("d", modifierFlags: [.command])
        let secondPane = app.otherElements["pane.1"]
        XCTAssertTrue(secondPane.waitForExistence(timeout: 5))
        XCTAssertLessThan(rootPane.frame.width, 800)

        app.typeKey("n", modifierFlags: [.command, .option])
        let thirdPane = app.otherElements["pane.2"]
        XCTAssertTrue(thirdPane.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(thirdPane.frame.width, 700)
    }
}
```

- [ ] **Step 2: Commit the UI test before running CI**

```bash
git add cmuxUITests/PaneStripUITests.swift
git commit -m "test: add pane strip smoke ui test"
```

- [ ] **Step 3: Trigger the GitHub Actions UI run**

Run:

```bash
gh workflow run test-e2e.yml --repo manaflow-ai/cmux \
  -f ref=issue-1221-paper-window-manager-layout \
  -f test_filter="PaneStripUITests" \
  -f record_video=true
```

Expected: Workflow queued successfully.

- [ ] **Step 4: Watch the run and fix any failures before continuing**

Run:

```bash
gh run list --repo manaflow-ai/cmux --workflow test-e2e.yml --limit 3
gh run watch --repo manaflow-ai/cmux <run-id>
```

Expected: PASS, with a downloadable recording confirming the initial pane fill and the split/open behavior.

- [ ] **Step 5: Commit any test fixes**

```bash
git add cmuxUITests/PaneStripUITests.swift
git commit -m "test: stabilize pane strip ui coverage"
```

## Final Verification

- [ ] `cd PaneKit && swift test --filter 'PaperCanvasStripStateTests|BonsplitTests'`
- [ ] `xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux-unit -destination 'platform=macOS' -derivedDataPath /tmp/cmux-pane-strip-stability test -only-testing:cmuxTests/WorkspacePaperCanvasTests -only-testing:cmuxTests/AppDelegateShortcutRoutingTests/testCmdOptionNOpensPaneRightWithoutShrinkingSourcePane -only-testing:cmuxTests/AppDelegateShortcutRoutingTests/testCmdShiftDDoesNotCreateVerticalPaneInPaperCanvasWorkspace -only-testing:cmuxTests/CommandPaletteSearchEngineTests/testPaneLayoutQueriesDifferentiateOpenPaneRightFromSplitRight -only-testing:cmuxTests/CommandPaletteSearchEngineTests/testCommandPaletteShortcutMappingIncludesOpenPaneRight`
- [ ] `./scripts/reload.sh --tag issue-1221-paper-window-manager-layout`
- [ ] Manually verify in the tagged app:
  - A fresh workspace starts with one full-width pane.
  - `Cmd+D` halves the current pane.
  - `Cmd+Opt+N` inserts a 66% pane to the right and reveals it with a stable motion.
  - The left pane remains partially visible after `Open Pane Right` when space allows.
  - `Cmd+Shift+D` still does nothing in paper-canvas mode.
  - Closing the middle pane focuses the left neighbor and does not scramble widths.

## Notes For The Implementer

- Do not delete `PaperCanvasLayoutSnapshot` in this plan. Too many higher layers already speak it.
- Do not make `PaperCanvasViewContainer` animate each pane independently. Animate one viewport scalar.
- Do not widen scope back into command/menu plumbing unless a compiler error forces it.
- If the strip model needs extra metadata later, add it internally first and preserve the current session wire format until migration is unavoidable.

