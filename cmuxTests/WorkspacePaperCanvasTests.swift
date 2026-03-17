import CoreGraphics
import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class WorkspacePaperCanvasTests: XCTestCase {
    private func sortedFrames(_ frames: [CGRect]) -> [CGRect] {
        frames.sorted { lhs, rhs in
            if abs(lhs.minX - rhs.minX) > 0.001 {
                return lhs.minX < rhs.minX
            }
            if abs(lhs.minY - rhs.minY) > 0.001 {
                return lhs.minY < rhs.minY
            }
            return lhs.width < rhs.width
        }
    }

    func testNewWorkspaceUsesPaperCanvasLayoutByDefault() {
        let workspace = Workspace()
        XCTAssertEqual(workspace.bonsplitController.layoutStyle, .paperCanvas)
        XCTAssertNotNil(workspace.bonsplitController.paperCanvasLayout())
    }

    func testSessionSnapshotRoundTripPreservesPaperPaneFramesAndViewport() throws {
        let workspace = Workspace()
        guard let rootPanelId = workspace.focusedPanelId,
              workspace.newTerminalSplit(from: rootPanelId, orientation: .horizontal) != nil else {
            XCTFail("Expected paper layout setup to succeed")
            return
        }
        XCTAssertTrue(
            workspace.bonsplitController.panPaperCanvasViewport(
                by: CGSize(width: 220, height: 0),
                notify: false
            )
        )
        guard let originalLayout = workspace.bonsplitController.paperCanvasLayout() else {
            XCTFail("Expected paper layout setup to succeed")
            return
        }

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)

        let restoredWorkspace = Workspace()
        restoredWorkspace.restoreSessionSnapshot(snapshot)

        guard let restoredLayout = restoredWorkspace.bonsplitController.paperCanvasLayout() else {
            XCTFail("Expected restored paper layout")
            return
        }

        let originalFrames = sortedFrames(originalLayout.panes.map(\.frame))
        let restoredFrames = sortedFrames(restoredLayout.panes.map(\.frame))
        XCTAssertEqual(restoredFrames.count, originalFrames.count)

        for (original, restored) in zip(originalFrames, restoredFrames) {
            XCTAssertEqual(restored.minX, original.minX, accuracy: 0.001)
            XCTAssertEqual(restored.minY, original.minY, accuracy: 0.001)
            XCTAssertEqual(restored.width, original.width, accuracy: 0.001)
            XCTAssertEqual(restored.height, original.height, accuracy: 0.001)
        }

        XCTAssertEqual(restoredLayout.viewportOrigin.x, originalLayout.viewportOrigin.x, accuracy: 0.001)
        XCTAssertEqual(restoredLayout.viewportOrigin.y, originalLayout.viewportOrigin.y, accuracy: 0.001)
    }

    func testRestoreLegacySplitSnapshotConvertsToPaperCanvas() {
        let firstPanelId = UUID()
        let secondPanelId = UUID()
        let snapshot = SessionWorkspaceSnapshot(
            processTitle: "Terminal",
            customTitle: nil,
            customColor: nil,
            isPinned: false,
            currentDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
            focusedPanelId: secondPanelId,
            layout: .split(
                SessionSplitLayoutSnapshot(
                    orientation: .horizontal,
                    dividerPosition: 0.5,
                    first: .pane(SessionPaneLayoutSnapshot(panelIds: [firstPanelId], selectedPanelId: firstPanelId)),
                    second: .pane(SessionPaneLayoutSnapshot(panelIds: [secondPanelId], selectedPanelId: secondPanelId))
                )
            ),
            panels: [
                SessionPanelSnapshot(
                    id: firstPanelId,
                    type: .terminal,
                    title: "First",
                    customTitle: nil,
                    directory: nil,
                    isPinned: false,
                    isManuallyUnread: false,
                    gitBranch: nil,
                    listeningPorts: [],
                    ttyName: nil,
                    terminal: SessionTerminalPanelSnapshot(workingDirectory: nil, scrollback: nil),
                    browser: nil,
                    markdown: nil
                ),
                SessionPanelSnapshot(
                    id: secondPanelId,
                    type: .terminal,
                    title: "Second",
                    customTitle: nil,
                    directory: nil,
                    isPinned: false,
                    isManuallyUnread: false,
                    gitBranch: nil,
                    listeningPorts: [],
                    ttyName: nil,
                    terminal: SessionTerminalPanelSnapshot(workingDirectory: nil, scrollback: nil),
                    browser: nil,
                    markdown: nil
                )
            ],
            statusEntries: [],
            logEntries: [],
            progress: nil,
            gitBranch: nil
        )

        let workspace = Workspace()
        workspace.restoreSessionSnapshot(snapshot)

        XCTAssertEqual(workspace.bonsplitController.layoutStyle, .paperCanvas)
        guard let layout = workspace.bonsplitController.paperCanvasLayout() else {
            return XCTFail("Expected restored paper layout")
        }
        XCTAssertEqual(layout.panes.count, 2)
    }

    func testOpenBrowserSplitRightReusesRightmostPaneInPaperCanvas() throws {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let leftPanelId = workspace.focusedPanelId,
              let rightPanel = workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal),
              let rightPaneId = workspace.paneId(forPanelId: rightPanel.id),
              let url = URL(string: "https://example.com/paper-right") else {
            XCTFail("Expected paper split setup")
            return
        }

        let initialPaneCount = workspace.bonsplitController.allPaneIds.count

        guard let browserPanelId = manager.openBrowser(
            inWorkspace: workspace.id,
            url: url,
            preferSplitRight: true,
            insertAtEnd: true
        ) else {
            XCTFail("Expected browser panel to be created")
            return
        }

        XCTAssertEqual(workspace.bonsplitController.allPaneIds.count, initialPaneCount)
        XCTAssertEqual(workspace.paneId(forPanelId: browserPanelId), rightPaneId)
    }

    func testWorkspaceSplitRightPreservesSurfaceTabsInSourcePane() {
        let workspace = Workspace()
        guard let sourcePanelId = workspace.focusedPanelId,
              let sourcePaneId = workspace.paneId(forPanelId: sourcePanelId) else {
            XCTFail("Expected initial focused panel")
            return
        }

        XCTAssertNotNil(workspace.newTerminalSurface(inPane: sourcePaneId, focus: false))
        let sourcePaneTabCountBefore = workspace.bonsplitController.tabs(inPane: sourcePaneId).count

        XCTAssertNotNil(workspace.newTerminalSplit(from: sourcePanelId, orientation: .horizontal))
        XCTAssertEqual(workspace.bonsplitController.tabs(inPane: sourcePaneId).count, sourcePaneTabCountBefore)
        XCTAssertEqual(workspace.bonsplitController.allPaneIds.count, 2)
    }

    func testWorkspaceOpenTerminalPaneRightKeepsSourcePaneWidthAndRevealsNewPane() {
        let workspace = Workspace()
        workspace.bonsplitController.setContainerFrame(CGRect(x: 0, y: 0, width: 1200, height: 800))

        guard let sourcePanelId = workspace.focusedPanelId,
              let sourcePaneId = workspace.paneId(forPanelId: sourcePanelId),
              let sourceFrameBefore = workspace.bonsplitController.paperCanvasLayout()?.panes.first(where: { $0.paneId == sourcePaneId })?.frame else {
            XCTFail("Expected initial source pane")
            return
        }

        guard let newPanel = workspace.openTerminalPaneRight(from: sourcePanelId),
              let newPaneId = workspace.paneId(forPanelId: newPanel.id),
              let layout = workspace.bonsplitController.paperCanvasLayout(),
              let sourceFrameAfter = layout.panes.first(where: { $0.paneId == sourcePaneId })?.frame,
              let newFrame = layout.panes.first(where: { $0.paneId == newPaneId })?.frame else {
            XCTFail("Expected inserted right pane")
            return
        }

        XCTAssertEqual(layout.panes.count, 2)
        XCTAssertEqual(sourceFrameAfter.width, sourceFrameBefore.width, accuracy: 0.001)
        XCTAssertEqual(newFrame.width, 800, accuracy: 1.0)
        XCTAssertEqual(layout.viewportOrigin.x, newFrame.maxX - 1200, accuracy: 1.0)
    }
}
