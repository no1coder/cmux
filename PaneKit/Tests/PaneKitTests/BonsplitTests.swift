import XCTest
@testable import PaneKit
import AppKit
import SwiftUI

final class BonsplitTests: XCTestCase {
    @MainActor
    private final class LayoutProbeView: NSView {
        private(set) var sizeChangeCount = 0
        private(set) var originChangeCount = 0

        override func setFrameSize(_ newSize: NSSize) {
            if frame.size != newSize {
                sizeChangeCount += 1
            }
            super.setFrameSize(newSize)
        }

        override func setFrameOrigin(_ newOrigin: NSPoint) {
            if frame.origin != newOrigin {
                originChangeCount += 1
            }
            super.setFrameOrigin(newOrigin)
        }
    }

    @MainActor
    private struct LayoutProbeRepresentable: NSViewRepresentable {
        let probeView: LayoutProbeView

        func makeNSView(context: Context) -> LayoutProbeView {
            probeView
        }

        func updateNSView(_ nsView: LayoutProbeView, context: Context) {}
    }

    @MainActor
    private final class DropZoneModel: ObservableObject {
        @Published var zone: DropZone?
    }

    @MainActor
    private struct PaneDropInteractionHarness: View {
        @ObservedObject var model: DropZoneModel
        let probeView: LayoutProbeView

        var body: some View {
            PaneDropInteractionContainer(activeDropZone: model.zone) {
                LayoutProbeRepresentable(probeView: probeView)
            } dropLayer: { _ in
                Color.clear
            }
        }
    }

    private final class TabContextActionDelegateSpy: BonsplitDelegate {
        var action: TabContextAction?
        var tabId: TabID?
        var paneId: PaneID?

        func splitTabBar(_ controller: BonsplitController, didRequestTabContextAction action: TabContextAction, for tab: PaneKit.Tab, inPane pane: PaneID) {
            self.action = action
            self.tabId = tab.id
            self.paneId = pane
        }
    }

    @MainActor
    func testControllerCreation() {
        let controller = BonsplitController()
        XCTAssertNotNil(controller.focusedPaneId)
    }

    @MainActor
    func testTabCreation() {
        let controller = BonsplitController()
        let tabId = controller.createTab(title: "Test Tab", icon: "doc")
        XCTAssertNotNil(tabId)
    }

    @MainActor
    func testTabRetrieval() {
        let controller = BonsplitController()
        let tabId = controller.createTab(title: "Test Tab", icon: "doc")!
        let tab = controller.tab(tabId)
        XCTAssertEqual(tab?.title, "Test Tab")
        XCTAssertEqual(tab?.icon, "doc")
    }

    @MainActor
    func testTabUpdate() {
        let controller = BonsplitController()
        let tabId = controller.createTab(title: "Original", icon: "doc")!

        controller.updateTab(tabId, title: "Updated", isDirty: true)

        let tab = controller.tab(tabId)
        XCTAssertEqual(tab?.title, "Updated")
        XCTAssertEqual(tab?.isDirty, true)
    }

    @MainActor
    func testTabClose() {
        let controller = BonsplitController()
        let tabId = controller.createTab(title: "Test Tab", icon: "doc")!

        let closed = controller.closeTab(tabId)

        XCTAssertTrue(closed)
        XCTAssertNil(controller.tab(tabId))
    }

    @MainActor
    func testCloseSelectedTabKeepsIndexStableWhenPossible() {
        do {
            let config = BonsplitConfiguration(newTabPosition: .end)
            let controller = BonsplitController(configuration: config)

            let tab0 = controller.createTab(title: "0")!
            let tab1 = controller.createTab(title: "1")!
            let tab2 = controller.createTab(title: "2")!

            let pane = controller.focusedPaneId!

            controller.selectTab(tab1)
            XCTAssertEqual(controller.selectedTab(inPane: pane)?.id, tab1)

            _ = controller.closeTab(tab1)

            // Order is [0,1,2] and 1 was selected; after close we should select 2 (same index).
            XCTAssertEqual(controller.selectedTab(inPane: pane)?.id, tab2)
            XCTAssertNotNil(controller.tab(tab0))
        }

        do {
            let config = BonsplitConfiguration(newTabPosition: .end)
            let controller = BonsplitController(configuration: config)

            let tab0 = controller.createTab(title: "0")!
            let tab1 = controller.createTab(title: "1")!
            let tab2 = controller.createTab(title: "2")!

            let pane = controller.focusedPaneId!

            controller.selectTab(tab2)
            XCTAssertEqual(controller.selectedTab(inPane: pane)?.id, tab2)

            _ = controller.closeTab(tab2)

            // Closing last should select previous.
            XCTAssertEqual(controller.selectedTab(inPane: pane)?.id, tab1)
            XCTAssertNotNil(controller.tab(tab0))
        }
    }

    @MainActor
    func testConfiguration() {
        let config = BonsplitConfiguration(
            allowSplits: false,
            allowCloseTabs: true
        )
        let controller = BonsplitController(configuration: config)

        XCTAssertFalse(controller.configuration.allowSplits)
        XCTAssertTrue(controller.configuration.allowCloseTabs)
    }

    func testDefaultSplitButtonTooltips() {
        let defaults = BonsplitConfiguration.SplitButtonTooltips.default
        XCTAssertEqual(defaults.newTerminal, "New Terminal")
        XCTAssertEqual(defaults.newBrowser, "New Browser")
        XCTAssertEqual(defaults.splitRight, "Split Right")
        XCTAssertEqual(defaults.splitDown, "Split Down")
    }

    @MainActor
    func testConfigurationAcceptsCustomSplitButtonTooltips() {
        let customTooltips = BonsplitConfiguration.SplitButtonTooltips(
            newTerminal: "Terminal (⌘T)",
            newBrowser: "Browser (⌘⇧L)",
            splitRight: "Split Right (⌘D)",
            splitDown: "Split Down (⌘⇧D)"
        )
        let config = BonsplitConfiguration(
            appearance: .init(
                splitButtonTooltips: customTooltips
            )
        )
        let controller = BonsplitController(configuration: config)

        XCTAssertEqual(controller.configuration.appearance.splitButtonTooltips, customTooltips)
    }

    func testChromeBackgroundHexOverrideParsesForPaneBackground() {
        let appearance = BonsplitConfiguration.Appearance(
            chromeColors: .init(backgroundHex: "#FDF6E3")
        )
        let color = TabBarColors.nsColorPaneBackground(for: appearance).usingColorSpace(.sRGB)!

        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)

        XCTAssertEqual(Int(round(red * 255)), 253)
        XCTAssertEqual(Int(round(green * 255)), 246)
        XCTAssertEqual(Int(round(blue * 255)), 227)
        XCTAssertEqual(Int(round(alpha * 255)), 255)
    }

    func testChromeBorderHexOverrideParsesForSeparatorColor() {
        let appearance = BonsplitConfiguration.Appearance(
            chromeColors: .init(backgroundHex: "#272822", borderHex: "#112233")
        )
        let color = TabBarColors.nsColorSeparator(for: appearance).usingColorSpace(.sRGB)!

        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)

        XCTAssertEqual(Int(round(red * 255)), 17)
        XCTAssertEqual(Int(round(green * 255)), 34)
        XCTAssertEqual(Int(round(blue * 255)), 51)
        XCTAssertEqual(Int(round(alpha * 255)), 255)
    }

    func testInvalidChromeBackgroundHexFallsBackToPaneDefaultColor() {
        let appearance = BonsplitConfiguration.Appearance(
            chromeColors: .init(backgroundHex: "#ZZZZZZ")
        )
        let resolved = TabBarColors.nsColorPaneBackground(for: appearance).usingColorSpace(.sRGB)!
        let fallback = NSColor.textBackgroundColor.usingColorSpace(.sRGB)!

        var rr: CGFloat = 0
        var rg: CGFloat = 0
        var rb: CGFloat = 0
        var ra: CGFloat = 0
        resolved.getRed(&rr, green: &rg, blue: &rb, alpha: &ra)

        var fr: CGFloat = 0
        var fg: CGFloat = 0
        var fb: CGFloat = 0
        var fa: CGFloat = 0
        fallback.getRed(&fr, green: &fg, blue: &fb, alpha: &fa)

        XCTAssertEqual(rr, fr, accuracy: 0.0001)
        XCTAssertEqual(rg, fg, accuracy: 0.0001)
        XCTAssertEqual(rb, fb, accuracy: 0.0001)
        XCTAssertEqual(ra, fa, accuracy: 0.0001)
    }

    func testPartiallyInvalidChromeBackgroundHexFallsBackToPaneDefaultColor() {
        let appearance = BonsplitConfiguration.Appearance(
            chromeColors: .init(backgroundHex: "#FF000G")
        )
        let resolved = TabBarColors.nsColorPaneBackground(for: appearance).usingColorSpace(.sRGB)!
        let fallback = NSColor.textBackgroundColor.usingColorSpace(.sRGB)!

        var rr: CGFloat = 0
        var rg: CGFloat = 0
        var rb: CGFloat = 0
        var ra: CGFloat = 0
        resolved.getRed(&rr, green: &rg, blue: &rb, alpha: &ra)

        var fr: CGFloat = 0
        var fg: CGFloat = 0
        var fb: CGFloat = 0
        var fa: CGFloat = 0
        fallback.getRed(&fr, green: &fg, blue: &fb, alpha: &fa)

        XCTAssertEqual(rr, fr, accuracy: 0.0001)
        XCTAssertEqual(rg, fg, accuracy: 0.0001)
        XCTAssertEqual(rb, fb, accuracy: 0.0001)
        XCTAssertEqual(ra, fa, accuracy: 0.0001)
    }

    func testInactiveTextUsesLightForegroundOnDarkCustomChromeBackground() {
        let appearance = BonsplitConfiguration.Appearance(
            chromeColors: .init(backgroundHex: "#272822")
        )
        let color = TabBarColors.nsColorInactiveText(for: appearance).usingColorSpace(.sRGB)!

        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)

        XCTAssertGreaterThan(red, 0.5)
        XCTAssertGreaterThan(green, 0.5)
        XCTAssertGreaterThan(blue, 0.5)
        XCTAssertGreaterThan(alpha, 0.6)
    }

    func testSplitActionPressedStateUsesHigherContrast() {
        let appearance = BonsplitConfiguration.Appearance(
            chromeColors: .init(backgroundHex: "#272822")
        )

        let idleIcon = TabBarColors.nsColorSplitActionIcon(for: appearance, isPressed: false).usingColorSpace(.sRGB)!
        let pressedIcon = TabBarColors.nsColorSplitActionIcon(for: appearance, isPressed: true).usingColorSpace(.sRGB)!

        var idleAlpha: CGFloat = 0
        idleIcon.getRed(nil, green: nil, blue: nil, alpha: &idleAlpha)
        var pressedAlpha: CGFloat = 0
        pressedIcon.getRed(nil, green: nil, blue: nil, alpha: &pressedAlpha)

        XCTAssertGreaterThan(pressedAlpha, idleAlpha)
    }

    @MainActor
    func testMoveTabNoopAfterItself() {
        let t0 = TabItem(title: "0")
        let t1 = TabItem(title: "1")
        let pane = PaneState(tabs: [t0, t1], selectedTabId: t1.id)

        // Dragging the last tab to the right corresponds to moving it to `tabs.count`,
        // which should be treated as a no-op.
        pane.moveTab(from: 1, to: 2)
        XCTAssertEqual(pane.tabs.map(\.id), [t0.id, t1.id])
        XCTAssertEqual(pane.selectedTabId, t1.id)

        // Still allow real moves.
        pane.moveTab(from: 0, to: 2)
        XCTAssertEqual(pane.tabs.map(\.id), [t1.id, t0.id])
        XCTAssertEqual(pane.selectedTabId, t1.id)
    }

    @MainActor
    func testPinnedTabInsertionsStayAheadOfUnpinnedTabs() {
        let unpinnedA = TabItem(title: "A", isPinned: false)
        let unpinnedB = TabItem(title: "B", isPinned: false)
        let pinned = TabItem(title: "Pinned", isPinned: true)
        let pane = PaneState(tabs: [unpinnedA, unpinnedB], selectedTabId: unpinnedA.id)

        pane.insertTab(pinned, at: 2)

        XCTAssertEqual(pane.tabs.map(\.isPinned), [true, false, false])
        XCTAssertEqual(pane.tabs.first?.id, pinned.id)
    }

    @MainActor
    func testMovingUnpinnedTabCannotCrossPinnedBoundary() {
        let pinnedA = TabItem(title: "Pinned A", isPinned: true)
        let pinnedB = TabItem(title: "Pinned B", isPinned: true)
        let unpinnedA = TabItem(title: "A", isPinned: false)
        let unpinnedB = TabItem(title: "B", isPinned: false)
        let pane = PaneState(
            tabs: [pinnedA, pinnedB, unpinnedA, unpinnedB],
            selectedTabId: unpinnedB.id
        )

        // Attempt to move an unpinned tab ahead of pinned tabs; move should clamp to
        // the first unpinned position.
        pane.moveTab(from: 3, to: 0)

        XCTAssertEqual(pane.tabs.map(\.id), [pinnedA.id, pinnedB.id, unpinnedB.id, unpinnedA.id])
        XCTAssertEqual(pane.tabs.prefix(2).allSatisfy(\.isPinned), true)
        XCTAssertEqual(pane.tabs.suffix(2).allSatisfy { !$0.isPinned }, true)
    }

    @MainActor
    func testCreateTabStoresKindAndPinnedState() {
        let controller = BonsplitController()
        let tabId = controller.createTab(
            title: "Browser",
            icon: "globe",
            kind: "browser",
            isPinned: true
        )!

        let tab = controller.tab(tabId)
        XCTAssertEqual(tab?.kind, "browser")
        XCTAssertEqual(tab?.isPinned, true)
    }

    @MainActor
    func testCreateAndUpdateTabCustomTitleFlag() {
        let controller = BonsplitController()
        let tabId = controller.createTab(
            title: "Infra",
            hasCustomTitle: true
        )!

        XCTAssertEqual(controller.tab(tabId)?.hasCustomTitle, true)

        controller.updateTab(tabId, hasCustomTitle: false)
        XCTAssertEqual(controller.tab(tabId)?.hasCustomTitle, false)
    }

    @MainActor
    func testSplitPaneWithOptionalTabPreservesCustomTitleFlag() {
        let controller = BonsplitController()
        _ = controller.createTab(title: "Base")
        let sourcePaneId = controller.focusedPaneId!
        let customTab = PaneKit.Tab(title: "Custom", hasCustomTitle: true)

        guard let newPaneId = controller.splitPane(sourcePaneId, orientation: .horizontal, withTab: customTab) else {
            return XCTFail("Expected splitPane to return new pane")
        }
        let inserted = controller.tabs(inPane: newPaneId).first(where: { $0.id == customTab.id })
        XCTAssertEqual(inserted?.hasCustomTitle, true)
    }

    @MainActor
    func testSplitPaneWithInsertSidePreservesCustomTitleFlag() {
        let controller = BonsplitController(
            configuration: BonsplitConfiguration(layoutStyle: .splitTree)
        )
        _ = controller.createTab(title: "Base")
        let sourcePaneId = controller.focusedPaneId!
        let customTab = PaneKit.Tab(title: "Custom", hasCustomTitle: true)

        guard let newPaneId = controller.splitPane(
            sourcePaneId,
            orientation: .vertical,
            withTab: customTab,
            insertFirst: true
        ) else {
            return XCTFail("Expected splitPane(insertFirst:) to return new pane")
        }
        let inserted = controller.tabs(inPane: newPaneId).first(where: { $0.id == customTab.id })
        XCTAssertEqual(inserted?.hasCustomTitle, true)
    }

    @MainActor
    func testTogglePaneZoomTracksState() {
        let controller = BonsplitController()
        guard let originalPane = controller.focusedPaneId else {
            return XCTFail("Expected focused pane")
        }

        // Single-pane layouts cannot be zoomed.
        XCTAssertFalse(controller.togglePaneZoom(inPane: originalPane))
        XCTAssertNil(controller.zoomedPaneId)

        guard controller.splitPane(originalPane, orientation: .horizontal) != nil else {
            return XCTFail("Expected splitPane to create a new pane")
        }

        XCTAssertTrue(controller.togglePaneZoom(inPane: originalPane))
        XCTAssertEqual(controller.zoomedPaneId, originalPane)
        XCTAssertTrue(controller.isSplitZoomed)

        XCTAssertTrue(controller.togglePaneZoom(inPane: originalPane))
        XCTAssertNil(controller.zoomedPaneId)
        XCTAssertFalse(controller.isSplitZoomed)
    }

    @MainActor
    func testSplitClearsExistingPaneZoom() {
        let controller = BonsplitController(
            configuration: BonsplitConfiguration(layoutStyle: .splitTree)
        )
        guard let originalPane = controller.focusedPaneId else {
            return XCTFail("Expected focused pane")
        }

        guard let secondPane = controller.splitPane(originalPane, orientation: .horizontal) else {
            return XCTFail("Expected splitPane to create a new pane")
        }

        XCTAssertTrue(controller.togglePaneZoom(inPane: secondPane))
        XCTAssertEqual(controller.zoomedPaneId, secondPane)

        _ = controller.splitPane(secondPane, orientation: .vertical)
        XCTAssertNil(controller.zoomedPaneId, "Splitting should reset zoom state")
    }

    @MainActor
    func testRequestTabContextActionForwardsToDelegate() {
        let controller = BonsplitController()
        let pane = controller.focusedPaneId!
        let tabId = controller.createTab(title: "Test", kind: "browser")!
        let spy = TabContextActionDelegateSpy()
        controller.delegate = spy

        controller.requestTabContextAction(.reload, for: tabId, inPane: pane)

        XCTAssertEqual(spy.action, .reload)
        XCTAssertEqual(spy.tabId, tabId)
        XCTAssertEqual(spy.paneId, pane)
    }

    @MainActor
    func testRequestTabContextActionForwardsMarkAsReadToDelegate() {
        let controller = BonsplitController()
        let pane = controller.focusedPaneId!
        let tabId = controller.createTab(title: "Test", kind: "terminal")!
        let spy = TabContextActionDelegateSpy()
        controller.delegate = spy

        controller.requestTabContextAction(.markAsRead, for: tabId, inPane: pane)

        XCTAssertEqual(spy.action, .markAsRead)
        XCTAssertEqual(spy.tabId, tabId)
        XCTAssertEqual(spy.paneId, pane)
    }

    @MainActor
    func testPaperCanvasSplitRightKeepsLocalSplitBehaviorInSingleRow() {
        let controller = BonsplitController(
            configuration: BonsplitConfiguration(layoutStyle: .paperCanvas)
        )
        controller.setContainerFrame(CGRect(x: 0, y: 0, width: 1200, height: 800))

        guard let originalPane = controller.focusedPaneId,
              let originalFrameBefore = controller.paperCanvasLayout()?.panes.first(where: { $0.paneId == originalPane })?.frame else {
            return XCTFail("Expected initial paper pane")
        }

        guard let newPane = controller.splitPane(originalPane, orientation: .horizontal),
              let originalFrameAfter = controller.paperCanvasLayout()?.panes.first(where: { $0.paneId == originalPane })?.frame,
              let newFrame = controller.paperCanvasLayout()?.panes.first(where: { $0.paneId == newPane })?.frame else {
            return XCTFail("Expected split paper panes")
        }

        XCTAssertEqual(Set([originalFrameAfter.minY, newFrame.minY]), [0])
        XCTAssertLessThan(originalFrameAfter.width, originalFrameBefore.width)
        XCTAssertEqual(originalFrameAfter.maxX + 16, newFrame.minX, accuracy: 1.0)
    }

    @MainActor
    func testPaperCanvasSinglePaneExpandsToFirstRealViewportSize() {
        let controller = BonsplitController(
            configuration: BonsplitConfiguration(layoutStyle: .paperCanvas)
        )

        controller.setContainerFrame(CGRect(x: 0, y: 0, width: 1400, height: 900))

        guard let layout = controller.paperCanvasLayout(),
              let onlyFrame = layout.panes.first?.frame else {
            return XCTFail("Expected paper canvas layout after viewport sizing")
        }

        XCTAssertEqual(layout.panes.count, 1)
        XCTAssertEqual(onlyFrame.origin.x, 0, accuracy: 0.001)
        XCTAssertEqual(onlyFrame.origin.y, 0, accuracy: 0.001)
        XCTAssertEqual(onlyFrame.width, 1400, accuracy: 1.0)
        XCTAssertEqual(onlyFrame.height, 900, accuracy: 1.0)
    }

    @MainActor
    func testPaperCanvasSplitDownIsRejectedInHorizontalPaneStripMode() {
        let controller = BonsplitController(
            configuration: BonsplitConfiguration(layoutStyle: .paperCanvas)
        )
        controller.setContainerFrame(CGRect(x: 0, y: 0, width: 1200, height: 800))

        guard let originalPane = controller.focusedPaneId else {
            return XCTFail("Expected focused paper pane")
        }
        guard let originalFrame = controller.paperCanvasLayout()?.panes.first(where: { $0.paneId == originalPane })?.frame else {
            return XCTFail("Expected initial paper layout")
        }

        XCTAssertNil(controller.splitPane(originalPane, orientation: .vertical))
        XCTAssertEqual(controller.allPaneIds.count, 1)

        guard let layout = controller.paperCanvasLayout(),
              let onlyFrame = layout.panes.first?.frame else {
            return XCTFail("Expected unchanged paper layout")
        }

        XCTAssertEqual(layout.panes.count, 1)
        XCTAssertEqual(onlyFrame, originalFrame)
    }

    @MainActor
    func testPaperCanvasSplitLocallyReflowsWhenPaneCanFitTwoChildren() {
        let controller = BonsplitController(
            configuration: BonsplitConfiguration(layoutStyle: .paperCanvas)
        )
        controller.setContainerFrame(CGRect(x: 0, y: 0, width: 1200, height: 800))

        guard let originalPane = controller.focusedPaneId else {
            return XCTFail("Expected focused pane")
        }
        guard let originalFrameBefore = controller.internalController.paperCanvas?.pane(originalPane)?.frame else {
            return XCTFail("Expected original paper-pane frame")
        }

        guard let newPane = controller.splitPane(originalPane, orientation: .horizontal) else {
            return XCTFail("Expected paper split to create a pane")
        }
        guard let originalFrameAfter = controller.internalController.paperCanvas?.pane(originalPane)?.frame,
              let newFrame = controller.internalController.paperCanvas?.pane(newPane)?.frame else {
            return XCTFail("Expected paper-pane frames after split")
        }

        XCTAssertLessThan(originalFrameAfter.width, originalFrameBefore.width)
        XCTAssertEqual(originalFrameAfter.height, originalFrameBefore.height)
        XCTAssertEqual(originalFrameAfter.origin.x, originalFrameBefore.origin.x)
        XCTAssertEqual(originalFrameAfter.origin.y, originalFrameBefore.origin.y)
        XCTAssertEqual(originalFrameAfter.width, newFrame.width, accuracy: 1.0)
        XCTAssertEqual(originalFrameAfter.maxX + 16, newFrame.minX, accuracy: 1.0)
        XCTAssertEqual(newFrame.size.height, originalFrameAfter.size.height, accuracy: 0.001)
    }

    @MainActor
    func testPaperCanvasNavigationMovesViewportToFocusedNeighbor() {
        let controller = BonsplitController(
            configuration: BonsplitConfiguration(
                layoutStyle: .paperCanvas,
                appearance: BonsplitConfiguration.Appearance(minimumPaneWidth: 260)
            )
        )
        controller.setContainerFrame(CGRect(x: 0, y: 0, width: 1000, height: 700))

        guard let originalPane = controller.focusedPaneId else {
            return XCTFail("Expected focused pane")
        }
        guard let farRightPane = controller.splitPane(originalPane, orientation: .horizontal) else {
            return XCTFail("Expected split pane")
        }
        controller.focusPane(originalPane)
        guard let overflowPane = controller.splitPane(originalPane, orientation: .horizontal) else {
            return XCTFail("Expected overflow split pane")
        }

        controller.focusPane(overflowPane)
        let beforeOrigin = controller.internalController.paperViewportOrigin

        controller.navigateFocus(direction: .right)

        XCTAssertEqual(controller.focusedPaneId, farRightPane)
        XCTAssertGreaterThan(controller.internalController.paperViewportOrigin.x, beforeOrigin.x)
    }

    @MainActor
    func testPaperCanvasFocusRevealUsesExactStripVisibilityWithoutExtraMargin() {
        let controller = BonsplitController(
            configuration: BonsplitConfiguration(layoutStyle: .paperCanvas)
        )
        controller.setContainerFrame(CGRect(x: 0, y: 0, width: 1200, height: 800))

        guard let firstPane = controller.focusedPaneId,
              let secondPane = controller.openPaperCanvasPaneRight(firstPane),
              let thirdPane = controller.openPaperCanvasPaneRight(secondPane) else {
            return XCTFail("Expected paper pane strip")
        }

        controller.focusPane(thirdPane)
        XCTAssertTrue(controller.panPaperCanvasViewport(by: CGSize(width: -4000, height: 0)))
        XCTAssertEqual(controller.internalController.paperViewportOrigin.x, 0, accuracy: 0.001)

        controller.focusPane(secondPane)

        XCTAssertEqual(controller.internalController.paperViewportOrigin.x, 816, accuracy: 1.0)
    }

    @MainActor
    func testPaperCanvasSplitSpillsAndShiftsExistingPaneChainOnceMinimumWidthIsReached() {
        let controller = BonsplitController(
            configuration: BonsplitConfiguration(
                layoutStyle: .paperCanvas,
                appearance: BonsplitConfiguration.Appearance(minimumPaneWidth: 260)
            )
        )
        controller.setContainerFrame(CGRect(x: 0, y: 0, width: 1000, height: 700))

        guard let rootPane = controller.focusedPaneId else {
            return XCTFail("Expected focused pane")
        }
        guard let firstRightPane = controller.splitPane(rootPane, orientation: .horizontal) else {
            return XCTFail("Expected first split")
        }
        controller.focusPane(rootPane)
        guard let secondRightPane = controller.splitPane(rootPane, orientation: .horizontal) else {
            return XCTFail("Expected second split")
        }

        guard let rootFrame = controller.internalController.paperCanvas?.pane(rootPane)?.frame,
              let firstRightFrame = controller.internalController.paperCanvas?.pane(firstRightPane)?.frame,
              let secondRightFrame = controller.internalController.paperCanvas?.pane(secondRightPane)?.frame else {
            return XCTFail("Expected paper-pane frames")
        }

        XCTAssertEqual(rootFrame.width, firstRightFrame.width, accuracy: 1.0)
        XCTAssertGreaterThanOrEqual(secondRightFrame.minX, rootFrame.maxX)
        XCTAssertGreaterThanOrEqual(firstRightFrame.minX, secondRightFrame.maxX)
    }

    @MainActor
    func testPaperCanvasResizeShiftsNeighborChain() {
        let controller = BonsplitController(
            configuration: BonsplitConfiguration(layoutStyle: .paperCanvas)
        )
        controller.setContainerFrame(CGRect(x: 0, y: 0, width: 1000, height: 700))

        guard let rootPane = controller.focusedPaneId,
              let rightPane = controller.splitPane(rootPane, orientation: .horizontal),
              let farRightPane = controller.splitPane(rightPane, orientation: .horizontal),
              let rootFrameBefore = controller.paperCanvasLayout()?.panes.first(where: { $0.paneId == rootPane })?.frame,
              let rightFrameBefore = controller.paperCanvasLayout()?.panes.first(where: { $0.paneId == rightPane })?.frame,
              let farRightFrameBefore = controller.paperCanvasLayout()?.panes.first(where: { $0.paneId == farRightPane })?.frame else {
            return XCTFail("Expected initial paper layout")
        }

        XCTAssertTrue(controller.resizePaperPane(rootPane, direction: .right, amount: 120))

        guard let rootFrameAfter = controller.paperCanvasLayout()?.panes.first(where: { $0.paneId == rootPane })?.frame,
              let rightFrameAfter = controller.paperCanvasLayout()?.panes.first(where: { $0.paneId == rightPane })?.frame,
              let farRightFrameAfter = controller.paperCanvasLayout()?.panes.first(where: { $0.paneId == farRightPane })?.frame else {
            return XCTFail("Expected resized paper layout")
        }

        XCTAssertEqual(rootFrameAfter.width, rootFrameBefore.width + 120, accuracy: 0.001)
        XCTAssertEqual(rightFrameAfter.minX, rightFrameBefore.minX + 120, accuracy: 0.001)
        XCTAssertEqual(farRightFrameAfter.minX, farRightFrameBefore.minX + 120, accuracy: 0.001)
        XCTAssertEqual(controller.focusedPaneId, rootPane)
    }

    @MainActor
    func testPaperCanvasApplyLayoutRestoresFramesAndViewport() {
        let controller = BonsplitController(
            configuration: BonsplitConfiguration(layoutStyle: .paperCanvas)
        )
        controller.setContainerFrame(CGRect(x: 0, y: 0, width: 900, height: 600))

        guard let rootPane = controller.focusedPaneId,
              let rightPane = controller.splitPane(rootPane, orientation: .horizontal) else {
            return XCTFail("Expected initial paper layout")
        }

        let layout = PaperCanvasLayoutSnapshot(
            panes: [
                PaperCanvasPaneSnapshot(
                    paneId: rootPane,
                    frame: CGRect(x: 0, y: 0, width: 900, height: 600)
                ),
                PaperCanvasPaneSnapshot(
                    paneId: rightPane,
                    frame: CGRect(x: 980, y: 120, width: 900, height: 600)
                )
            ],
            viewportOrigin: CGPoint(x: 820, y: 90),
            focusedPaneId: rightPane
        )

        XCTAssertTrue(controller.applyPaperCanvasLayout(layout))

        guard let restored = controller.paperCanvasLayout(),
              let rootFrame = restored.panes.first(where: { $0.paneId == rootPane })?.frame,
              let rightFrame = restored.panes.first(where: { $0.paneId == rightPane })?.frame else {
            return XCTFail("Expected restored paper layout")
        }

        XCTAssertEqual(rootFrame.origin.x, 0, accuracy: 0.001)
        XCTAssertEqual(rightFrame.origin.x, 916, accuracy: 0.001)
        XCTAssertEqual(rightFrame.origin.y, 120, accuracy: 0.001)
        XCTAssertEqual(restored.viewportOrigin.x, 820, accuracy: 0.001)
        XCTAssertEqual(restored.viewportOrigin.y, 90, accuracy: 0.001)
        XCTAssertEqual(restored.focusedPaneId, rightPane)
    }

    @MainActor
    func testPaperCanvasViewportPanUpdatesAndClampsToCanvasBounds() {
        let controller = BonsplitController(
            configuration: BonsplitConfiguration(layoutStyle: .paperCanvas)
        )
        controller.setContainerFrame(CGRect(x: 0, y: 0, width: 900, height: 600))

        guard let rootPane = controller.focusedPaneId,
              let rightPane = controller.splitPane(rootPane, orientation: .horizontal) else {
            return XCTFail("Expected initial paper layout")
        }

        let layout = PaperCanvasLayoutSnapshot(
            panes: [
                PaperCanvasPaneSnapshot(
                    paneId: rootPane,
                    frame: CGRect(x: 0, y: 0, width: 900, height: 600)
                ),
                PaperCanvasPaneSnapshot(
                    paneId: rightPane,
                    frame: CGRect(x: 980, y: 120, width: 900, height: 600)
                )
            ],
            viewportOrigin: .zero,
            focusedPaneId: rootPane
        )

        XCTAssertTrue(controller.applyPaperCanvasLayout(layout))
        XCTAssertTrue(controller.panPaperCanvasViewport(by: CGSize(width: 820, height: 200)))

        guard let afterFirstPan = controller.paperCanvasLayout() else {
            return XCTFail("Expected paper layout after first pan")
        }
        XCTAssertEqual(afterFirstPan.viewportOrigin.x, 820, accuracy: 0.001)
        XCTAssertEqual(afterFirstPan.viewportOrigin.y, 120, accuracy: 0.001)

        XCTAssertTrue(controller.panPaperCanvasViewport(by: CGSize(width: 500, height: 500)))
        guard let afterOverflowPan = controller.paperCanvasLayout() else {
            return XCTFail("Expected paper layout after overflow pan")
        }
        XCTAssertEqual(afterOverflowPan.viewportOrigin.x, 916, accuracy: 0.001)
        XCTAssertEqual(afterOverflowPan.viewportOrigin.y, 120, accuracy: 0.001)

        XCTAssertTrue(controller.panPaperCanvasViewport(by: CGSize(width: -2000, height: -2000)))
        guard let afterReversePan = controller.paperCanvasLayout() else {
            return XCTFail("Expected paper layout after reverse pan")
        }
        XCTAssertEqual(afterReversePan.viewportOrigin.x, 0, accuracy: 0.001)
        XCTAssertEqual(afterReversePan.viewportOrigin.y, 0, accuracy: 0.001)
    }

    @MainActor
    func testPaperCanvasOpenPaneRightInsertsViewportSizedSiblingWithoutShrinkingCurrentPane() {
        let controller = BonsplitController(
            configuration: BonsplitConfiguration(layoutStyle: .paperCanvas)
        )
        controller.setContainerFrame(CGRect(x: 0, y: 0, width: 1200, height: 800))

        guard let originalPane = controller.focusedPaneId,
              let originalFrameBefore = controller.paperCanvasLayout()?.panes.first(where: { $0.paneId == originalPane })?.frame else {
            return XCTFail("Expected initial paper pane")
        }

        guard let newPane = controller.openPaperCanvasPaneRight(originalPane),
              let layout = controller.paperCanvasLayout(),
              let originalFrameAfter = layout.panes.first(where: { $0.paneId == originalPane })?.frame,
              let newFrame = layout.panes.first(where: { $0.paneId == newPane })?.frame else {
            return XCTFail("Expected inserted paper pane")
        }

        XCTAssertEqual(layout.panes.count, 2)
        XCTAssertEqual(originalFrameAfter.width, originalFrameBefore.width, accuracy: 0.001)
        XCTAssertEqual(newFrame.minX, originalFrameBefore.maxX + 16, accuracy: 0.001)
        XCTAssertEqual(newFrame.width, 800, accuracy: 1.0)
        XCTAssertEqual(layout.viewportOrigin.x, newFrame.maxX - 1200, accuracy: 1.0)
        XCTAssertGreaterThan(originalFrameAfter.maxX - layout.viewportOrigin.x, 0)
    }

    @MainActor
    func testPaperCanvasLayoutSnapshotIsDerivedFromStripState() {
        let controller = BonsplitController(
            configuration: BonsplitConfiguration(layoutStyle: .paperCanvas)
        )
        controller.setContainerFrame(CGRect(x: 0, y: 0, width: 1400, height: 900))

        guard let rootPane = controller.focusedPaneId,
              let insertedPane = controller.openPaperCanvasPaneRight(rootPane),
              let layout = controller.paperCanvasLayout(),
              let rootFrame = layout.panes.first(where: { $0.paneId == rootPane })?.frame,
              let insertedFrame = layout.panes.first(where: { $0.paneId == insertedPane })?.frame else {
            return XCTFail("Expected paper canvas layout after opening pane")
        }

        XCTAssertEqual(layout.panes.map(\.frame.minY), [0, 0])
        XCTAssertEqual(rootFrame.width, 1400, accuracy: 1.0)
        XCTAssertEqual(insertedFrame.width, 933, accuracy: 1.0)
    }

    @MainActor
    func testApplyPaperCanvasLayoutRestoresOrderedStripWidthsFromFrames() {
        let controller = BonsplitController(
            configuration: BonsplitConfiguration(layoutStyle: .paperCanvas)
        )
        controller.setContainerFrame(CGRect(x: 0, y: 0, width: 1200, height: 800))

        guard let firstPane = controller.focusedPaneId,
              let secondPane = controller.openPaperCanvasPaneRight(firstPane) else {
            return XCTFail("Expected initial paper panes")
        }

        let snapshot = PaperCanvasLayoutSnapshot(
            panes: [
                .init(paneId: firstPane, frame: CGRect(x: 0, y: 0, width: 600, height: 800)),
                .init(paneId: secondPane, frame: CGRect(x: 616, y: 0, width: 800, height: 800))
            ],
            viewportOrigin: CGPoint(x: 216, y: 0),
            focusedPaneId: secondPane
        )

        XCTAssertTrue(controller.applyPaperCanvasLayout(snapshot))

        guard let restored = controller.paperCanvasLayout() else {
            return XCTFail("Expected restored paper layout")
        }

        XCTAssertEqual(restored.panes.count, 2)
        XCTAssertEqual(restored.panes[0].frame.minX, 0, accuracy: 1.0)
        XCTAssertEqual(restored.panes[1].frame.minX, 616, accuracy: 1.0)
        XCTAssertEqual(restored.viewportOrigin.x, 216, accuracy: 1.0)
        XCTAssertEqual(restored.focusedPaneId, secondPane)
    }

    @MainActor
    func testPaperCanvasCloseUsesStripNeighborFocusRules() {
        let controller = BonsplitController(
            configuration: BonsplitConfiguration(layoutStyle: .paperCanvas)
        )
        controller.setContainerFrame(CGRect(x: 0, y: 0, width: 1200, height: 800))

        guard let firstPane = controller.focusedPaneId,
              let secondPane = controller.openPaperCanvasPaneRight(firstPane),
              let thirdPane = controller.openPaperCanvasPaneRight(secondPane) else {
            return XCTFail("Expected paper pane strip")
        }

        controller.focusPane(secondPane)
        XCTAssertTrue(controller.closePane(secondPane))

        XCTAssertEqual(controller.focusedPaneId, firstPane)
        XCTAssertEqual(controller.allPaneIds, [firstPane, thirdPane])
    }

    @MainActor
    func testPaperCanvasEqualizeUsesStripOrderRatherThanLegacySplitTree() {
        let controller = BonsplitController(
            configuration: BonsplitConfiguration(layoutStyle: .paperCanvas)
        )
        controller.setContainerFrame(CGRect(x: 0, y: 0, width: 1200, height: 800))

        guard let firstPane = controller.focusedPaneId,
              let secondPane = controller.openPaperCanvasPaneRight(firstPane) else {
            return XCTFail("Expected paper panes")
        }

        XCTAssertTrue(controller.resizePaperPane(firstPane, direction: .right, amount: 160))
        XCTAssertTrue(controller.equalizePaperPanes())

        guard let layout = controller.paperCanvasLayout(),
              let firstFrame = layout.panes.first(where: { $0.paneId == firstPane })?.frame,
              let secondFrame = layout.panes.first(where: { $0.paneId == secondPane })?.frame else {
            return XCTFail("Expected equalized paper layout")
        }

        XCTAssertEqual(firstFrame.width, secondFrame.width, accuracy: 1.0)
    }

    func testIconSaturationKeepsRasterFaviconInColorWhenInactive() {
        XCTAssertEqual(
            TabItemStyling.iconSaturation(hasRasterIcon: true, tabSaturation: 0.0),
            1.0
        )
    }

    func testIconSaturationStillDesaturatesSymbolIconsWhenInactive() {
        XCTAssertEqual(
            TabItemStyling.iconSaturation(hasRasterIcon: false, tabSaturation: 0.0),
            0.0
        )
    }

    func testResolvedFaviconImageUsesIncomingDataWhenDecodable() {
        let existing = NSImage(size: NSSize(width: 12, height: 12))
        let incoming = NSImage(size: NSSize(width: 16, height: 16))
        incoming.lockFocus()
        NSColor.systemBlue.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 16, height: 16)).fill()
        incoming.unlockFocus()
        let data = incoming.tiffRepresentation

        let resolved = TabItemStyling.resolvedFaviconImage(existing: existing, incomingData: data)
        XCTAssertNotNil(resolved)
        XCTAssertFalse(resolved === existing)
    }

    func testResolvedFaviconImageKeepsExistingImageWhenIncomingDataIsInvalid() {
        let existing = NSImage(size: NSSize(width: 16, height: 16))
        let invalidData = Data([0x00, 0x11, 0x22, 0x33])

        let resolved = TabItemStyling.resolvedFaviconImage(existing: existing, incomingData: invalidData)
        XCTAssertTrue(resolved === existing)
    }

    func testResolvedFaviconImageClearsWhenIncomingDataIsNil() {
        let existing = NSImage(size: NSSize(width: 16, height: 16))
        let resolved = TabItemStyling.resolvedFaviconImage(existing: existing, incomingData: nil)
        XCTAssertNil(resolved)
    }

    func testTabControlShortcutHintPolicyRequiresCommandOrControlOnly() {
        withShortcutHintDefaultsSuite { defaults in
            defaults.set(true, forKey: TabControlShortcutHintPolicy.showHintsOnCommandHoldKey)

            XCTAssertNotNil(TabControlShortcutHintPolicy.hintModifier(for: [.control], defaults: defaults))
            XCTAssertNotNil(TabControlShortcutHintPolicy.hintModifier(for: [.command], defaults: defaults))
            XCTAssertNil(TabControlShortcutHintPolicy.hintModifier(for: [], defaults: defaults))
            XCTAssertNil(TabControlShortcutHintPolicy.hintModifier(for: [.control, .shift], defaults: defaults))
            XCTAssertNil(TabControlShortcutHintPolicy.hintModifier(for: [.command, .option], defaults: defaults))
        }
    }

    func testTabControlShortcutHintPolicyCanDisableHoldHints() {
        withShortcutHintDefaultsSuite { defaults in
            defaults.set(false, forKey: TabControlShortcutHintPolicy.showHintsOnCommandHoldKey)

            XCTAssertNil(TabControlShortcutHintPolicy.hintModifier(for: [.command], defaults: defaults))
            XCTAssertNil(TabControlShortcutHintPolicy.hintModifier(for: [.control], defaults: defaults))
        }
    }

    func testTabControlShortcutHintPolicyDefaultsToShowingHoldHints() {
        withShortcutHintDefaultsSuite { defaults in
            defaults.removeObject(forKey: TabControlShortcutHintPolicy.showHintsOnCommandHoldKey)

            XCTAssertEqual(TabControlShortcutHintPolicy.hintModifier(for: [.command], defaults: defaults), .command)
            XCTAssertEqual(TabControlShortcutHintPolicy.hintModifier(for: [.control], defaults: defaults), .control)
        }
    }

    func testTabControlShortcutHintsAreScopedToCurrentKeyWindow() {
        withShortcutHintDefaultsSuite { defaults in
            defaults.set(true, forKey: TabControlShortcutHintPolicy.showHintsOnCommandHoldKey)

            XCTAssertTrue(
                TabControlShortcutHintPolicy.shouldShowHints(
                    for: [.command],
                    hostWindowNumber: 42,
                    hostWindowIsKey: true,
                    eventWindowNumber: 42,
                    keyWindowNumber: 42,
                    defaults: defaults
                )
            )

            XCTAssertFalse(
                TabControlShortcutHintPolicy.shouldShowHints(
                    for: [.command],
                    hostWindowNumber: 42,
                    hostWindowIsKey: true,
                    eventWindowNumber: 7,
                    keyWindowNumber: 42,
                    defaults: defaults
                )
            )

            XCTAssertFalse(
                TabControlShortcutHintPolicy.shouldShowHints(
                    for: [.command],
                    hostWindowNumber: 42,
                    hostWindowIsKey: false,
                    eventWindowNumber: 42,
                    keyWindowNumber: 42,
                    defaults: defaults
                )
            )
        }
    }

    func testTabControlShortcutHintsFallbackToKeyWindowWhenEventWindowMissing() {
        withShortcutHintDefaultsSuite { defaults in
            defaults.set(true, forKey: TabControlShortcutHintPolicy.showHintsOnCommandHoldKey)

            XCTAssertTrue(
                TabControlShortcutHintPolicy.shouldShowHints(
                    for: [.control],
                    hostWindowNumber: 42,
                    hostWindowIsKey: true,
                    eventWindowNumber: nil,
                    keyWindowNumber: 42,
                    defaults: defaults
                )
            )

            XCTAssertFalse(
                TabControlShortcutHintPolicy.shouldShowHints(
                    for: [.control],
                    hostWindowNumber: 42,
                    hostWindowIsKey: true,
                    eventWindowNumber: nil,
                    keyWindowNumber: 7,
                    defaults: defaults
                )
            )
        }
    }

    func testSelectedTabNeverShowsHoverBackground() {
        XCTAssertFalse(
            TabItemStyling.shouldShowHoverBackground(isHovered: true, isSelected: true)
        )
        XCTAssertTrue(
            TabItemStyling.shouldShowHoverBackground(isHovered: true, isSelected: false)
        )
        XCTAssertFalse(
            TabItemStyling.shouldShowHoverBackground(isHovered: false, isSelected: false)
        )
    }

    func testTabBarSeparatorSegmentsClampGapIntoBounds() {
        var segments = TabBarStyling.separatorSegments(totalWidth: 100, gap: -20...40)
        XCTAssertEqual(segments.left, 0, accuracy: 0.0001)
        XCTAssertEqual(segments.right, 60, accuracy: 0.0001)

        segments = TabBarStyling.separatorSegments(totalWidth: 100, gap: 25...120)
        XCTAssertEqual(segments.left, 25, accuracy: 0.0001)
        XCTAssertEqual(segments.right, 0, accuracy: 0.0001)

        segments = TabBarStyling.separatorSegments(totalWidth: 100, gap: nil)
        XCTAssertEqual(segments.left, 100, accuracy: 0.0001)
        XCTAssertEqual(segments.right, 0, accuracy: 0.0001)
    }

    @MainActor
    func testPaneDropOverlayDoesNotResizeHostedContentDuringHover() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let model = DropZoneModel()
        let probeView = LayoutProbeView(frame: .zero)
        let hostingView = NSHostingView(
            rootView: PaneDropInteractionHarness(
                model: model,
                probeView: probeView
            )
        )
        hostingView.frame = contentView.bounds
        hostingView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostingView)

        window.makeKeyAndOrderFront(nil)
        contentView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        contentView.layoutSubtreeIfNeeded()

        let initialFrame = probeView.frame
        let initialSizeChanges = probeView.sizeChangeCount
        let initialOriginChanges = probeView.originChangeCount

        model.zone = .left
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        contentView.layoutSubtreeIfNeeded()

        XCTAssertEqual(probeView.frame, initialFrame)
        XCTAssertEqual(
            probeView.sizeChangeCount,
            initialSizeChanges,
            "Drag-hover overlays must not resize the hosted pane content"
        )
        XCTAssertEqual(
            probeView.originChangeCount,
            initialOriginChanges,
            "Drag-hover overlays must not move the hosted pane content"
        )

        model.zone = .bottom
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        contentView.layoutSubtreeIfNeeded()

        XCTAssertEqual(probeView.frame, initialFrame)
        XCTAssertEqual(
            probeView.sizeChangeCount,
            initialSizeChanges,
            "Switching hover targets should keep the hosted pane geometry stable"
        )
        XCTAssertEqual(
            probeView.originChangeCount,
            initialOriginChanges,
            "Switching hover targets should not reposition the hosted pane content"
        )
    }

    private func withShortcutHintDefaultsSuite(_ body: (UserDefaults) -> Void) {
        let suiteName = "BonsplitShortcutHintPolicyTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create defaults suite")
            return
        }

        defaults.removePersistentDomain(forName: suiteName)
        body(defaults)
        defaults.removePersistentDomain(forName: suiteName)
    }
}
