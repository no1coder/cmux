import CoreGraphics
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
        guard let frame = frames[paneId] else {
            return XCTFail("Expected bootstrap frame")
        }

        XCTAssertEqual(frame.width, 1400, accuracy: 1.0)
        XCTAssertEqual(frame.height, 900, accuracy: 1.0)
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
        guard let right,
              let leftFrame = frames[left],
              let rightFrame = frames[right] else {
            return XCTFail("Expected split frames")
        }

        XCTAssertEqual(leftFrame.maxX + 16, rightFrame.minX, accuracy: 1.0)
        XCTAssertEqual(leftFrame.width, rightFrame.width, accuracy: 1.0)
        XCTAssertEqual(leftFrame.maxX, 592, accuracy: 2.0)
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
        guard let leftFrame = frames[left],
              let insertedFrame = frames[inserted] else {
            return XCTFail("Expected opened pane frames")
        }

        XCTAssertEqual(leftFrame.width, 1200, accuracy: 1.0)
        XCTAssertEqual(insertedFrame.width, 800, accuracy: 1.0)
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
        XCTAssertEqual(state.items.map { $0.paneId }, [first, third])
    }

    func testRevealPaneUsesMinimalHorizontalViewportShift() {
        let first = PaneID()
        var state = PaperCanvasStripState.bootstrap(
            paneId: first,
            viewportSize: CGSize(width: 1200, height: 800),
            paneGap: 16
        )
        let second = state.openPaneRight(after: first, requestedWidth: 800, minimumPaneWidth: 260)

        state.setViewportOriginX(0)
        state.revealPane(second)

        XCTAssertEqual(state.viewportOriginX, 816, accuracy: 1.0)
    }

    func testOverflowHintsReflectHiddenNeighborPanes() {
        let first = PaneID()
        var state = PaperCanvasStripState.bootstrap(
            paneId: first,
            viewportSize: CGSize(width: 1200, height: 800),
            paneGap: 16
        )
        let second = state.openPaneRight(after: first, requestedWidth: 800, minimumPaneWidth: 260)

        state.setViewportOriginX(0)
        XCTAssertFalse(state.showsLeftOverflowHint)
        XCTAssertTrue(state.showsRightOverflowHint)

        state.revealPane(second)
        XCTAssertTrue(state.showsLeftOverflowHint)
        XCTAssertFalse(state.showsRightOverflowHint)
    }
}
