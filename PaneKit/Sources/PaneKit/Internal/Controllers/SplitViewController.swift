import Foundation
import SwiftUI

/// Central controller managing the pane layout state (internal implementation)
@Observable
@MainActor
final class SplitViewController {
    /// The legacy split-tree root. This remains available for the classic layout path
    /// and for bootstrapping a paper canvas from an existing restored tree.
    var rootNode: SplitNode

    var layoutStyle: PaneLayoutStyle
    var minimumPaneWidth: CGFloat
    var minimumPaneHeight: CGFloat
    var paperCanvas: PaperCanvasState?

    /// Currently zoomed pane. When set, rendering should only show this pane.
    var zoomedPaneId: PaneID?

    /// Currently focused pane ID
    var focusedPaneId: PaneID?

    /// Tab currently being dragged (for visual feedback and hit-testing).
    /// This is @Observable so SwiftUI views react (e.g. allowsHitTesting).
    var draggingTab: TabItem?

    /// Monotonic counter incremented on each drag start. Used to invalidate stale
    /// timeout timers that would otherwise cancel a new drag of the same tab.
    var dragGeneration: Int = 0

    /// Source pane of the dragging tab
    var dragSourcePaneId: PaneID?

    /// Non-observable drag session state. Drop delegates read these instead of the
    /// @Observable properties above, because SwiftUI batches observable updates and
    /// createItemProvider's writes may not be visible to validateDrop/performDrop yet.
    @ObservationIgnored var activeDragTab: TabItem?
    @ObservationIgnored var activeDragSourcePaneId: PaneID?

    /// When false, drop delegates reject all drags and NSViews are hidden.
    /// Mirrors BonsplitController.isInteractive. Must be observable so
    /// updateNSView is called to toggle isHidden on the AppKit containers.
    var isInteractive: Bool = true

    /// Handler for file/URL drops from external apps (e.g. Finder).
    /// Receives the dropped URLs and the pane ID where the drop occurred.
    @ObservationIgnored var onFileDrop: ((_ urls: [URL], _ paneId: PaneID) -> Bool)?

    /// During drop, SwiftUI may keep the source tab view alive briefly (default removal animation)
    /// even after we've updated the model. Hide it explicitly so it disappears immediately.
    var dragHiddenSourceTabId: UUID?
    var dragHiddenSourcePaneId: PaneID?

    /// Current frame of the entire split view container
    var containerFrame: CGRect = .zero

    /// Flag to prevent notification loops during external updates
    var isExternalUpdateInProgress: Bool = false

    /// Timestamp of last geometry notification for debouncing
    var lastGeometryNotificationTime: TimeInterval = 0

    /// Callback for geometry changes
    var onGeometryChange: (() -> Void)?

    var paperViewportOrigin: CGPoint {
        paperCanvas?.viewportOrigin ?? .zero
    }

    init(
        rootNode: SplitNode? = nil,
        layoutStyle: PaneLayoutStyle = .splitTree,
        minimumPaneWidth: CGFloat = 100,
        minimumPaneHeight: CGFloat = 100
    ) {
        self.layoutStyle = layoutStyle
        self.minimumPaneWidth = minimumPaneWidth
        self.minimumPaneHeight = minimumPaneHeight

        if let rootNode {
            self.rootNode = rootNode
            self.focusedPaneId = rootNode.allPaneIds.first
        } else {
            let welcomeTab = TabItem(title: "Welcome", icon: "star")
            let initialPane = PaneState(tabs: [welcomeTab])
            self.rootNode = .pane(initialPane)
            self.focusedPaneId = initialPane.id
        }

        if layoutStyle == .paperCanvas {
            enablePaperCanvasLayout()
        }
    }

    func applyConfiguration(_ configuration: BonsplitConfiguration) {
        minimumPaneWidth = configuration.appearance.minimumPaneWidth
        minimumPaneHeight = configuration.appearance.minimumPaneHeight

        guard layoutStyle != configuration.layoutStyle else {
            if layoutStyle == .paperCanvas {
                paperCanvas?.updateViewportSize(effectiveViewportSize())
            }
            return
        }

        layoutStyle = configuration.layoutStyle
        switch layoutStyle {
        case .splitTree:
            paperCanvas = nil
        case .paperCanvas:
            enablePaperCanvasLayout()
        }
    }

    func setPaperViewportFrame(_ frame: CGRect) {
        containerFrame = frame
        guard layoutStyle == .paperCanvas else { return }
        if paperCanvas == nil {
            enablePaperCanvasLayout()
        }
        paperCanvas?.updateViewportSize(frame.size)
        if let focusedPaneId,
           let frame = paperCanvas?.pane(focusedPaneId)?.frame {
            paperCanvas?.reveal(frame, margin: 0)
        }
    }

    func paperCanvasLayoutSnapshot() -> PaperCanvasLayoutSnapshot? {
        guard layoutStyle == .paperCanvas else { return nil }
        return paperCanvas?.layoutSnapshot(focusedPaneId: focusedPaneId)
    }

    @discardableResult
    func applyPaperCanvasLayout(_ layout: PaperCanvasLayoutSnapshot) -> Bool {
        guard layoutStyle == .paperCanvas else { return false }
        if paperCanvas == nil {
            enablePaperCanvasLayout()
        }

        let paneFrames = Dictionary(uniqueKeysWithValues: layout.panes.map { ($0.paneId, $0.frame) })
        paperCanvas?.applyLayout(
            paneFrames: paneFrames,
            viewportOrigin: layout.viewportOrigin,
            focusedPaneId: layout.focusedPaneId
        )

        if let focusedPaneId = layout.focusedPaneId,
           paneState(focusedPaneId) != nil {
            self.focusedPaneId = focusedPaneId
        } else if self.focusedPaneId == nil {
            self.focusedPaneId = paperCanvas?.allPaneIds.first
        }

        return true
    }

    @discardableResult
    func setPaperCanvasViewportOrigin(_ origin: CGPoint) -> Bool {
        guard layoutStyle == .paperCanvas else { return false }
        if paperCanvas == nil {
            enablePaperCanvasLayout()
        }
        paperCanvas?.setViewportOrigin(origin)
        return paperCanvas != nil
    }

    @discardableResult
    func panPaperCanvasViewport(by delta: CGSize) -> Bool {
        guard layoutStyle == .paperCanvas else { return false }
        if paperCanvas == nil {
            enablePaperCanvasLayout()
        }
        paperCanvas?.panViewport(by: delta)
        return paperCanvas != nil
    }

    var allPaneIds: [PaneID] {
        switch layoutStyle {
        case .splitTree:
            return rootNode.allPaneIds
        case .paperCanvas:
            return paperCanvas?.allPaneIds ?? []
        }
    }

    var allPanes: [PaneState] {
        switch layoutStyle {
        case .splitTree:
            return rootNode.allPanes
        case .paperCanvas:
            return paperCanvas?.allPanes ?? []
        }
    }

    func paneState(_ paneId: PaneID) -> PaneState? {
        switch layoutStyle {
        case .splitTree:
            return rootNode.findPane(paneId)
        case .paperCanvas:
            return paperCanvas?.pane(paneId)?.pane
        }
    }

    func paneBounds() -> [PaneBounds] {
        switch layoutStyle {
        case .splitTree:
            return rootNode.computePaneBounds()
        case .paperCanvas:
            return paperCanvas?.panes.map { PaneBounds(paneId: $0.pane.id, bounds: $0.frame) } ?? []
        }
    }

    // MARK: - Focus Management

    func focusPane(_ paneId: PaneID) {
        guard paneState(paneId) != nil else { return }
#if DEBUG
        dlog("focus.bonsplit pane=\(paneId.id.uuidString.prefix(5))")
#endif
        focusedPaneId = paneId
        if layoutStyle == .paperCanvas {
            paperCanvas?.revealPane(paneId)
        }
    }

    var focusedPane: PaneState? {
        guard let focusedPaneId else { return nil }
        return paneState(focusedPaneId)
    }

    var zoomedNode: SplitNode? {
        guard layoutStyle == .splitTree, let zoomedPaneId else { return nil }
        return rootNode.findNode(containing: zoomedPaneId)
    }

    @discardableResult
    func clearPaneZoom() -> Bool {
        guard zoomedPaneId != nil else { return false }
        zoomedPaneId = nil
        return true
    }

    @discardableResult
    func togglePaneZoom(_ paneId: PaneID) -> Bool {
        guard paneState(paneId) != nil else { return false }

        if zoomedPaneId == paneId {
            zoomedPaneId = nil
            return true
        }

        guard allPaneIds.count > 1 else { return false }
        zoomedPaneId = paneId
        focusedPaneId = paneId
        return true
    }

    // MARK: - Split Operations

    func splitPane(_ paneId: PaneID, orientation: SplitOrientation, with newTab: TabItem? = nil) {
        switch layoutStyle {
        case .splitTree:
            clearPaneZoom()
            rootNode = splitNodeRecursively(
                node: rootNode,
                targetPaneId: paneId,
                orientation: orientation,
                newTab: newTab
            )
        case .paperCanvas:
            splitPaperPane(paneId, orientation: orientation, newTab: newTab, insertFirst: false)
        }
    }

    func splitPaneWithTab(_ paneId: PaneID, orientation: SplitOrientation, tab: TabItem, insertFirst: Bool) {
        switch layoutStyle {
        case .splitTree:
            clearPaneZoom()
            rootNode = splitNodeWithTabRecursively(
                node: rootNode,
                targetPaneId: paneId,
                orientation: orientation,
                tab: tab,
                insertFirst: insertFirst
            )
        case .paperCanvas:
            splitPaperPane(paneId, orientation: orientation, newTab: tab, insertFirst: insertFirst)
        }
    }

    @discardableResult
    func openPaperCanvasPaneRight(_ paneId: PaneID, newTab: TabItem? = nil) -> PaneID? {
        guard layoutStyle == .paperCanvas else { return nil }
        clearPaneZoom()
        if paperCanvas == nil {
            enablePaperCanvasLayout()
        }
        guard let paperCanvas,
              paperCanvas.pane(paneId) != nil else {
            return nil
        }

        let newPane = PaneState(tabs: newTab.map { [$0] } ?? [])
        guard let newFrame = paperCanvas.insertPaneRight(
            newPane,
            after: paneId,
            requestedWidth: floor(paperCanvas.viewportSize.width * (2.0 / 3.0)),
            minimumSize: CGSize(width: minimumPaneWidth, height: minimumPaneHeight)
        ) else {
            return nil
        }
        focusedPaneId = newPane.id
        paperCanvas.setViewportOrigin(
            CGPoint(
                x: newFrame.maxX - paperCanvas.viewportSize.width,
                y: paperCanvas.viewportOrigin.y
            )
        )
        return newPane.id
    }

    private func splitPaperPane(
        _ paneId: PaneID,
        orientation: SplitOrientation,
        newTab: TabItem?,
        insertFirst: Bool
    ) {
        clearPaneZoom()
        guard let paperCanvas,
              paperCanvas.supportsTopLevelSplit(orientation),
              let target = paperCanvas.pane(paneId) else {
            return
        }

        let newPane = PaneState(tabs: newTab.map { [$0] } ?? [])
        let placement: PaperCanvasState.SplitPlacement
        switch orientation {
        case .horizontal:
            guard !insertFirst,
                  let stripPlacement = paperCanvas.splitPaneRight(
                      paneId,
                      newPane: newPane,
                      minimumSize: CGSize(width: minimumPaneWidth, height: minimumPaneHeight)
                  ) else {
                return
            }
            placement = stripPlacement
        case .vertical:
            placement = paperCanvas.resolvedSplitPlacement(
                for: target.frame,
                orientation: orientation,
                insertFirst: insertFirst,
                minimumSize: CGSize(width: minimumPaneWidth, height: minimumPaneHeight)
            )
            target.frame = placement.existingFrame
            _ = paperCanvas.addPane(newPane, frame: placement.newFrame)
        }

        focusedPaneId = newPane.id
        switch placement.mode {
        case .localReflow:
            paperCanvas.reveal(placement.newFrame, margin: 0)
        case .canvasOverflow:
            paperCanvas.centerViewport(on: placement.newFrame)
        }
    }

    private func splitNodeRecursively(
        node: SplitNode,
        targetPaneId: PaneID,
        orientation: SplitOrientation,
        newTab: TabItem?
    ) -> SplitNode {
        switch node {
        case .pane(let paneState):
            if paneState.id == targetPaneId {
                let newPane = newTab.map { PaneState(tabs: [$0]) } ?? PaneState(tabs: [])
                let splitState = SplitState(
                    orientation: orientation,
                    first: .pane(paneState),
                    second: .pane(newPane),
                    dividerPosition: 0.5,
                    animationOrigin: .fromSecond
                )
                focusedPaneId = newPane.id
                return .split(splitState)
            }
            return node

        case .split(let splitState):
            splitState.first = splitNodeRecursively(
                node: splitState.first,
                targetPaneId: targetPaneId,
                orientation: orientation,
                newTab: newTab
            )
            splitState.second = splitNodeRecursively(
                node: splitState.second,
                targetPaneId: targetPaneId,
                orientation: orientation,
                newTab: newTab
            )
            return .split(splitState)
        }
    }

    private func splitNodeWithTabRecursively(
        node: SplitNode,
        targetPaneId: PaneID,
        orientation: SplitOrientation,
        tab: TabItem,
        insertFirst: Bool
    ) -> SplitNode {
        switch node {
        case .pane(let paneState):
            if paneState.id == targetPaneId {
                let newPane = PaneState(tabs: [tab])
                let splitState: SplitState
                if insertFirst {
                    splitState = SplitState(
                        orientation: orientation,
                        first: .pane(newPane),
                        second: .pane(paneState),
                        dividerPosition: 0.5,
                        animationOrigin: .fromFirst
                    )
                } else {
                    splitState = SplitState(
                        orientation: orientation,
                        first: .pane(paneState),
                        second: .pane(newPane),
                        dividerPosition: 0.5,
                        animationOrigin: .fromSecond
                    )
                }
                focusedPaneId = newPane.id
                return .split(splitState)
            }
            return node

        case .split(let splitState):
            splitState.first = splitNodeWithTabRecursively(
                node: splitState.first,
                targetPaneId: targetPaneId,
                orientation: orientation,
                tab: tab,
                insertFirst: insertFirst
            )
            splitState.second = splitNodeWithTabRecursively(
                node: splitState.second,
                targetPaneId: targetPaneId,
                orientation: orientation,
                tab: tab,
                insertFirst: insertFirst
            )
            return .split(splitState)
        }
    }

    func closePane(_ paneId: PaneID) {
        guard allPaneIds.count > 1 else { return }

        switch layoutStyle {
        case .splitTree:
            let (newRoot, siblingPaneId) = closePaneRecursively(node: rootNode, targetPaneId: paneId)

            if let newRoot {
                rootNode = newRoot
            }

            if let siblingPaneId {
                focusedPaneId = siblingPaneId
            } else if let firstPane = rootNode.allPaneIds.first {
                focusedPaneId = firstPane
            }

            if let zoomedPaneId, rootNode.findPane(zoomedPaneId) == nil {
                self.zoomedPaneId = nil
            }
        case .paperCanvas:
            guard let paperCanvas,
                  let closingPane = paperCanvas.pane(paneId) else {
                return
            }

            let closingFrame = closingPane.frame
            let closeResult = paperCanvas.removePane(paneId, preferredFocus: focusedPaneId)

            if let zoomedPaneId, zoomedPaneId == paneId {
                self.zoomedPaneId = nil
            }

            if let nextFocus = closeResult?.nextFocus
                ?? findBestNeighbor(
                    from: closingFrame,
                    currentPaneId: paneId,
                    directionCandidates: paneBounds()
                )
                ?? paperCanvas.allPaneIds.first {
                focusedPaneId = nextFocus
                paperCanvas.revealPane(nextFocus)
            }
        }
    }

    private func closePaneRecursively(
        node: SplitNode,
        targetPaneId: PaneID
    ) -> (SplitNode?, PaneID?) {
        switch node {
        case .pane(let paneState):
            if paneState.id == targetPaneId {
                return (nil, nil)
            }
            return (node, nil)

        case .split(let splitState):
            if case .pane(let firstPane) = splitState.first, firstPane.id == targetPaneId {
                return (splitState.second, splitState.second.allPaneIds.first)
            }

            if case .pane(let secondPane) = splitState.second, secondPane.id == targetPaneId {
                return (splitState.first, splitState.first.allPaneIds.first)
            }

            let (newFirst, focusFromFirst) = closePaneRecursively(node: splitState.first, targetPaneId: targetPaneId)
            if newFirst == nil {
                return (splitState.second, splitState.second.allPaneIds.first)
            }

            let (newSecond, focusFromSecond) = closePaneRecursively(node: splitState.second, targetPaneId: targetPaneId)
            if newSecond == nil {
                return (splitState.first, splitState.first.allPaneIds.first)
            }

            if let newFirst { splitState.first = newFirst }
            if let newSecond { splitState.second = newSecond }

            return (.split(splitState), focusFromFirst ?? focusFromSecond)
        }
    }

    // MARK: - Tab Operations

    func addTab(_ tab: TabItem, toPane paneId: PaneID? = nil, atIndex index: Int? = nil) {
        let targetPaneId = paneId ?? focusedPaneId
        guard let targetPaneId,
              let pane = paneState(targetPaneId) else { return }

        if let index {
            pane.insertTab(tab, at: index)
        } else {
            pane.addTab(tab)
        }
    }

    func moveTab(_ tab: TabItem, from sourcePaneId: PaneID, to targetPaneId: PaneID, atIndex index: Int? = nil) {
        guard let sourcePane = paneState(sourcePaneId),
              let targetPane = paneState(targetPaneId) else { return }

        _ = sourcePane.removeTab(tab.id)
        if let index {
            targetPane.insertTab(tab, at: index)
        } else {
            targetPane.addTab(tab)
        }

        focusPane(targetPaneId)

        if sourcePane.tabs.isEmpty && allPaneIds.count > 1 {
            closePane(sourcePaneId)
        }
    }

    func closeTab(_ tabId: UUID, inPane paneId: PaneID) {
        guard let pane = paneState(paneId) else { return }

        _ = pane.removeTab(tabId)
        if pane.tabs.isEmpty && allPaneIds.count > 1 {
            closePane(paneId)
        }
    }

    // MARK: - Keyboard Navigation

    func navigateFocus(direction: NavigationDirection) {
        guard let currentPaneId = focusedPaneId else { return }
        let allPaneBounds = paneBounds()
        guard let currentBounds = allPaneBounds.first(where: { $0.paneId == currentPaneId })?.bounds else { return }

        if let targetPaneId = findBestNeighbor(
            from: currentBounds,
            currentPaneId: currentPaneId,
            direction: direction,
            allPaneBounds: allPaneBounds
        ) {
            focusPane(targetPaneId)
        }
    }

    private func findBestNeighbor(
        from currentBounds: CGRect,
        currentPaneId: PaneID,
        direction: NavigationDirection,
        allPaneBounds: [PaneBounds]
    ) -> PaneID? {
        let epsilon: CGFloat = 0.001

        let candidates = allPaneBounds.filter { paneBounds in
            guard paneBounds.paneId != currentPaneId else { return false }
            let bounds = paneBounds.bounds
            switch direction {
            case .left:
                return bounds.maxX <= currentBounds.minX + epsilon
            case .right:
                return bounds.minX >= currentBounds.maxX - epsilon
            case .up:
                return bounds.maxY <= currentBounds.minY + epsilon
            case .down:
                return bounds.minY >= currentBounds.maxY - epsilon
            }
        }

        guard !candidates.isEmpty else { return nil }

        let scored: [(PaneID, CGFloat, CGFloat)] = candidates.map { candidate in
            let overlap: CGFloat
            let distance: CGFloat

            switch direction {
            case .left, .right:
                overlap = max(0, min(currentBounds.maxY, candidate.bounds.maxY) - max(currentBounds.minY, candidate.bounds.minY))
                distance = direction == .left ? (currentBounds.minX - candidate.bounds.maxX) : (candidate.bounds.minX - currentBounds.maxX)
            case .up, .down:
                overlap = max(0, min(currentBounds.maxX, candidate.bounds.maxX) - max(currentBounds.minX, candidate.bounds.minX))
                distance = direction == .up ? (currentBounds.minY - candidate.bounds.maxY) : (candidate.bounds.minY - currentBounds.maxY)
            }

            return (candidate.paneId, overlap, distance)
        }

        return scored.sorted { lhs, rhs in
            if abs(lhs.1 - rhs.1) > epsilon {
                return lhs.1 > rhs.1
            }
            return lhs.2 < rhs.2
        }.first?.0
    }

    private func findBestNeighbor(
        from currentBounds: CGRect,
        currentPaneId: PaneID,
        directionCandidates allPaneBounds: [PaneBounds]
    ) -> PaneID? {
        let preferredDirections: [NavigationDirection] = [.right, .left, .down, .up]
        for direction in preferredDirections {
            if let neighbor = findBestNeighbor(
                from: currentBounds,
                currentPaneId: currentPaneId,
                direction: direction,
                allPaneBounds: allPaneBounds
            ) {
                return neighbor
            }
        }
        return nil
    }

    @discardableResult
    func resizePaperPane(_ paneId: PaneID, direction: NavigationDirection, amount: CGFloat) -> CGRect? {
        guard layoutStyle == .paperCanvas else { return nil }
        if paperCanvas == nil {
            enablePaperCanvasLayout()
        }
        let minimumSize = CGSize(width: minimumPaneWidth, height: minimumPaneHeight)
        return paperCanvas?.resizePane(
            paneId,
            direction: direction,
            amount: amount,
            minimumSize: minimumSize
        )
    }

    @discardableResult
    func equalizePaperPanes() -> Bool {
        guard layoutStyle == .paperCanvas else { return false }
        if paperCanvas == nil {
            enablePaperCanvasLayout()
        }
        guard let paperCanvas else { return false }
        let equalized = paperCanvas.equalizePaneWidths(minimumWidth: minimumPaneWidth)
        if equalized,
           let focusedPaneId,
           let frame = paperCanvas.pane(focusedPaneId)?.frame {
            paperCanvas.reveal(frame, margin: 0)
        }
        return equalized
    }

    func createNewTab() {
        guard let pane = focusedPane else { return }
        let count = pane.tabs.count + 1
        let newTab = TabItem(title: "Untitled \(count)", icon: "doc")
        pane.addTab(newTab)
    }

    func closeSelectedTab() {
        guard let pane = focusedPane,
              let selectedTabId = pane.selectedTabId else { return }
        closeTab(selectedTabId, inPane: pane.id)
    }

    func selectPreviousTab() {
        guard let pane = focusedPane,
              let selectedTabId = pane.selectedTabId,
              let currentIndex = pane.tabs.firstIndex(where: { $0.id == selectedTabId }),
              !pane.tabs.isEmpty else { return }

        let newIndex = currentIndex > 0 ? currentIndex - 1 : pane.tabs.count - 1
        pane.selectTab(pane.tabs[newIndex].id)
    }

    func selectNextTab() {
        guard let pane = focusedPane,
              let selectedTabId = pane.selectedTabId,
              let currentIndex = pane.tabs.firstIndex(where: { $0.id == selectedTabId }),
              !pane.tabs.isEmpty else { return }

        let newIndex = currentIndex < pane.tabs.count - 1 ? currentIndex + 1 : 0
        pane.selectTab(pane.tabs[newIndex].id)
    }

    // MARK: - Split State Access

    func findSplit(_ splitId: UUID) -> SplitState? {
        guard layoutStyle == .splitTree else { return nil }
        return findSplitRecursively(in: rootNode, id: splitId)
    }

    private func findSplitRecursively(in node: SplitNode, id: UUID) -> SplitState? {
        switch node {
        case .pane:
            return nil
        case .split(let splitState):
            if splitState.id == id {
                return splitState
            }
            if let found = findSplitRecursively(in: splitState.first, id: id) {
                return found
            }
            return findSplitRecursively(in: splitState.second, id: id)
        }
    }

    var allSplits: [SplitState] {
        guard layoutStyle == .splitTree else { return [] }
        return collectSplits(from: rootNode)
    }

    private func collectSplits(from node: SplitNode) -> [SplitState] {
        switch node {
        case .pane:
            return []
        case .split(let splitState):
            return [splitState] + collectSplits(from: splitState.first) + collectSplits(from: splitState.second)
        }
    }

    // MARK: - Private Helpers

    private func enablePaperCanvasLayout() {
        let viewportSize = effectiveViewportSize()
        let normalizedBounds = rootNode.computePaneBounds(in: CGRect(origin: .zero, size: CGSize(width: 1, height: 1)))
        let placements = normalizedBounds.compactMap { paneBounds -> PaperCanvasPane? in
            guard let pane = rootNode.findPane(paneBounds.paneId) else { return nil }

            let resolvedFrame = CGRect(
                x: paneBounds.bounds.minX * viewportSize.width,
                y: paneBounds.bounds.minY * viewportSize.height,
                width: max(paneBounds.bounds.width * viewportSize.width, minimumPaneWidth),
                height: max(paneBounds.bounds.height * viewportSize.height, minimumPaneHeight)
            )
            return PaperCanvasPane(pane: pane, frame: resolvedFrame)
        }

        paperCanvas = PaperCanvasState(
            panes: placements.isEmpty ? [PaperCanvasPane(pane: initialPaperPane(), frame: CGRect(origin: .zero, size: viewportSize))] : placements,
            viewportSize: viewportSize
        )

        if focusedPaneId == nil {
            focusedPaneId = paperCanvas?.allPaneIds.first
        }
        if let focusedPaneId,
           let frame = paperCanvas?.pane(focusedPaneId)?.frame {
            paperCanvas?.reveal(frame, margin: 0)
        }
    }

    private func initialPaperPane() -> PaneState {
        if let existing = rootNode.allPanes.first {
            return existing
        }
        let welcomeTab = TabItem(title: "Welcome", icon: "star")
        return PaneState(tabs: [welcomeTab])
    }

    private func effectiveViewportSize() -> CGSize {
        let width = containerFrame.width > 0 ? containerFrame.width : max(minimumPaneWidth * 2, 960)
        let height = containerFrame.height > 0 ? containerFrame.height : max(minimumPaneHeight * 2, 640)
        return CGSize(width: width, height: height)
    }
}
