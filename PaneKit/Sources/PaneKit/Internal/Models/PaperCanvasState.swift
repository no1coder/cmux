import Foundation
import SwiftUI

@Observable
final class PaperCanvasPane: Identifiable {
    let pane: PaneState
    var frame: CGRect

    var id: PaneID { pane.id }

    init(pane: PaneState, frame: CGRect) {
        self.pane = pane
        self.frame = frame.integral
    }
}

@Observable
final class PaperCanvasState {
    struct SplitPlacement {
        enum Mode {
            case localReflow
            case canvasOverflow
        }

        let existingFrame: CGRect
        let newFrame: CGRect
        let mode: Mode
    }

    var panes: [PaperCanvasPane]
    var viewportOrigin: CGPoint
    var viewportSize: CGSize
    var canvasBounds: CGRect
    let paneGap: CGFloat
    private var stripState: PaperCanvasStripState

    var showsLeftOverflowHint: Bool {
        stripState.showsLeftOverflowHint
    }

    var showsRightOverflowHint: Bool {
        stripState.showsRightOverflowHint
    }

    init(
        panes: [PaperCanvasPane],
        viewportOrigin: CGPoint = .zero,
        viewportSize: CGSize = .zero,
        paneGap: CGFloat = 16
    ) {
        self.panes = panes
        self.viewportOrigin = viewportOrigin
        self.viewportSize = viewportSize
        self.paneGap = paneGap
        self.canvasBounds = .zero
        self.stripState = Self.makeStripState(
            from: panes,
            viewportSize: viewportSize,
            viewportOriginX: viewportOrigin.x,
            paneGap: paneGap
        )
        syncPaneFramesFromStripState()
        recomputeCanvasBounds()
        clampViewportOrigin()
    }

    func pane(_ paneId: PaneID) -> PaperCanvasPane? {
        return panes.first { $0.pane.id == paneId }
    }

    var allPanes: [PaneState] {
        panes.map(\.pane)
    }

    var allPaneIds: [PaneID] {
        panes.map(\.pane.id)
    }

    func layoutSnapshot(focusedPaneId: PaneID?) -> PaperCanvasLayoutSnapshot {
        recomputeCanvasBounds()
        return PaperCanvasLayoutSnapshot(
            panes: panes.map { PaperCanvasPaneSnapshot(paneId: $0.pane.id, frame: $0.frame) },
            viewportOrigin: viewportOrigin,
            canvasBounds: canvasBounds,
            focusedPaneId: focusedPaneId
        )
    }

    @discardableResult
    func addPane(_ pane: PaneState, frame: CGRect) -> PaperCanvasPane {
        let placement = PaperCanvasPane(pane: pane, frame: frame)
        panes.append(placement)
        rebuildStripStateFromPaneFrames()
        recomputeCanvasBounds()
        return placement
    }

    @discardableResult
    func removePane(_ paneId: PaneID) -> PaperCanvasPane? {
        guard let index = panes.firstIndex(where: { $0.pane.id == paneId }) else { return nil }
        let removed = panes.remove(at: index)
        rebuildStripStateFromPaneFrames()
        recomputeCanvasBounds()
        return removed
    }

    @discardableResult
    func removePane(_ paneId: PaneID, preferredFocus: PaneID?) -> (removed: PaperCanvasPane, nextFocus: PaneID?)? {
        guard let index = panes.firstIndex(where: { $0.pane.id == paneId }) else {
            return nil
        }

        let nextFocus = stripState.closePane(paneId, preferredFocus: preferredFocus)
        let removed = panes.remove(at: index)
        syncPaneFramesFromStripState()
        recomputeCanvasBounds()
        clampViewportOrigin()
        return (removed, nextFocus)
    }

    @discardableResult
    func insertPaneRight(
        _ newPane: PaneState,
        after targetPaneId: PaneID,
        requestedWidth: CGFloat,
        minimumSize: CGSize
    ) -> CGRect? {
        syncPaneFramesFromStripState()
        guard let target = pane(targetPaneId),
              stripState.openPaneRightIfPresent(
                  after: targetPaneId,
                  inserting: newPane.id,
                  requestedWidth: requestedWidth,
                  minimumPaneWidth: minimumSize.width
              ) else {
            return nil
        }

        panes.append(
            PaperCanvasPane(
                pane: newPane,
                frame: placeholderFrame(
                    nextTo: target.frame,
                    width: max(requestedWidth, minimumSize.width),
                    minimumHeight: minimumSize.height
                )
            )
        )
        syncPaneFramesFromStripState()
        recomputeCanvasBounds()
        clampViewportOrigin()
        return self.pane(newPane.id)?.frame
    }

    func splitPaneRight(
        _ targetPaneId: PaneID,
        newPane: PaneState,
        minimumSize: CGSize
    ) -> SplitPlacement? {
        syncPaneFramesFromStripState()
        guard let target = pane(targetPaneId) else {
            return nil
        }

        let targetFrame = target.frame
        let mode: SplitPlacement.Mode
        let placeholderWidth: CGFloat

        if stripState.splitRight(targetPaneId, inserting: newPane.id, minimumPaneWidth: minimumSize.width) {
            mode = .localReflow
            placeholderWidth = max(floor((targetFrame.width - paneGap) / 2), minimumSize.width)
        } else {
            guard stripState.openPaneRightIfPresent(
                after: targetPaneId,
                inserting: newPane.id,
                requestedWidth: targetFrame.width,
                minimumPaneWidth: minimumSize.width
            ) else {
                return nil
            }
            mode = .canvasOverflow
            placeholderWidth = max(targetFrame.width, minimumSize.width)
        }

        panes.append(
            PaperCanvasPane(
                pane: newPane,
                frame: placeholderFrame(
                    nextTo: targetFrame,
                    width: placeholderWidth,
                    minimumHeight: minimumSize.height
                )
            )
        )
        syncPaneFramesFromStripState()
        recomputeCanvasBounds()
        clampViewportOrigin()

        guard let existingFrame = pane(targetPaneId)?.frame,
              let newFrame = pane(newPane.id)?.frame else {
            return nil
        }

        return SplitPlacement(
            existingFrame: existingFrame,
            newFrame: newFrame,
            mode: mode
        )
    }

    func updateViewportSize(_ size: CGSize) {
        let previousViewportSize = viewportSize
        viewportSize = size
        expandSinglePaneToMatchViewportIfNeeded(previousViewportSize: previousViewportSize)
        stripState.updateViewportSize(size)
        syncPaneFramesFromStripState()
        recomputeCanvasBounds()
        clampViewportOrigin()
    }

    func reveal(_ frame: CGRect, margin: CGFloat = 32) {
        guard viewportSize.width > 0, viewportSize.height > 0 else { return }

        var nextOrigin = viewportOrigin
        if frame.minX < viewportOrigin.x + margin {
            nextOrigin.x = frame.minX - margin
        } else if frame.maxX > viewportOrigin.x + viewportSize.width - margin {
            nextOrigin.x = frame.maxX - viewportSize.width + margin
        }

        if frame.minY < viewportOrigin.y + margin {
            nextOrigin.y = frame.minY - margin
        } else if frame.maxY > viewportOrigin.y + viewportSize.height - margin {
            nextOrigin.y = frame.maxY - viewportSize.height + margin
        }

        viewportOrigin = nextOrigin
        clampViewportOrigin()
    }

    func centerViewport(on frame: CGRect) {
        guard viewportSize.width > 0, viewportSize.height > 0 else { return }

        viewportOrigin = CGPoint(
            x: frame.midX - viewportSize.width / 2,
            y: frame.midY - viewportSize.height / 2
        )
        clampViewportOrigin()
    }

    func revealPane(_ paneId: PaneID) {
        stripState.revealPane(paneId)
        viewportOrigin.x = stripState.viewportOriginX
        clampViewportOrigin()
    }

    func panViewport(by delta: CGSize) {
        viewportOrigin.x += delta.width
        viewportOrigin.y += delta.height
        clampViewportOrigin()
    }

    func recomputeCanvasBounds() {
        let union = panes.reduce(into: CGRect.null) { partial, placement in
            partial = partial.union(placement.frame)
        }

        let minimumBounds = CGRect(origin: .zero, size: viewportSize)
        canvasBounds = union.isNull ? minimumBounds : union.union(minimumBounds)
    }

    func clampViewportOrigin() {
        guard viewportSize.width > 0, viewportSize.height > 0 else { return }

        stripState.updateViewportSize(viewportSize)
        stripState.setViewportOriginX(viewportOrigin.x)

        let minX = canvasBounds.minX
        let maxX = max(canvasBounds.minX, canvasBounds.maxX - viewportSize.width)
        let minY = canvasBounds.minY
        let maxY = max(canvasBounds.minY, canvasBounds.maxY - viewportSize.height)

        viewportOrigin.x = min(max(stripState.viewportOriginX, minX), maxX)
        viewportOrigin.y = min(max(viewportOrigin.y, minY), maxY)
    }

    func setViewportOrigin(_ origin: CGPoint) {
        viewportOrigin = origin
        clampViewportOrigin()
    }

    private func expandSinglePaneToMatchViewportIfNeeded(previousViewportSize: CGSize) {
        guard panes.count == 1,
              sizeIsUsable(previousViewportSize),
              sizeIsUsable(viewportSize),
              let onlyPane = panes.first else {
            return
        }

        let previousViewportFrame = CGRect(origin: .zero, size: previousViewportSize).integral
        guard onlyPane.frame.equalTo(previousViewportFrame) else {
            return
        }

        onlyPane.frame = CGRect(origin: .zero, size: viewportSize).integral
    }

    private func sizeIsUsable(_ size: CGSize) -> Bool {
        size.width > 0 && size.height > 0
    }

    private func placeholderFrame(
        nextTo targetFrame: CGRect,
        width: CGFloat,
        minimumHeight: CGFloat
    ) -> CGRect {
        CGRect(
            x: targetFrame.maxX + paneGap,
            y: targetFrame.minY,
            width: width,
            height: max(targetFrame.height, minimumHeight)
        ).integral
    }

    func supportsTopLevelSplit(_ orientation: SplitOrientation) -> Bool {
        orientation == .horizontal
    }

    func openPaneRightPlacement(
        for targetFrame: CGRect,
        minimumSize: CGSize
    ) -> CGRect {
        syncPaneFramesFromStripState()

        let requestedWidth = max(floor(viewportSize.width * (2.0 / 3.0)), minimumSize.width)
        guard let targetPaneId = paneId(matching: targetFrame) else {
            let proposedFrame = CGRect(
                x: targetFrame.maxX + paneGap,
                y: targetFrame.minY,
                width: requestedWidth,
                height: max(targetFrame.height, minimumSize.height)
            )
            return resolveCollisions(for: proposedFrame, orientation: .horizontal, insertFirst: false)
        }

        var proposedStrip = stripState
        let newPaneId = proposedStrip.openPaneRight(
            after: targetPaneId,
            requestedWidth: requestedWidth,
            minimumPaneWidth: minimumSize.width
        )
        guard let stripFrame = proposedStrip.framesByPaneId()[newPaneId] else {
            let proposedFrame = CGRect(
                x: targetFrame.maxX + paneGap,
                y: targetFrame.minY,
                width: requestedWidth,
                height: max(targetFrame.height, minimumSize.height)
            )
            return resolveCollisions(for: proposedFrame, orientation: .horizontal, insertFirst: false)
        }

        return CGRect(
            x: stripFrame.minX,
            y: targetFrame.minY,
            width: stripFrame.width,
            height: max(targetFrame.height, minimumSize.height)
        ).integral
    }

    @discardableResult
    func equalizePaneWidths(minimumWidth: CGFloat) -> Bool {
        syncPaneFramesFromStripState()
        guard stripState.items.count > 1 else { return false }

        let paneCount = CGFloat(stripState.items.count)
        let minimumTotalWidth = max(0, minimumWidth) * paneCount
        let currentTotalWidth = max(0, stripState.items.reduce(0) { $0 + $1.width })
        let targetTotalWidth = max(currentTotalWidth, minimumTotalWidth)
        let baseWidth = floor(targetTotalWidth / paneCount)
        let trailingRemainder = targetTotalWidth - (baseWidth * paneCount)

        for index in stripState.items.indices {
            stripState.items[index].width = baseWidth + (index == stripState.items.count - 1 ? trailingRemainder : 0)
        }

        syncPaneFramesFromStripState()
        recomputeCanvasBounds()
        clampViewportOrigin()
        return true
    }

    func applyLayout(
        paneFrames: [PaneID: CGRect],
        viewportOrigin: CGPoint?,
        focusedPaneId _: PaneID?
    ) {
        for placement in panes {
            guard let frame = paneFrames[placement.pane.id] else { continue }
            placement.frame = frame.integral
        }

        rebuildStripStateFromPaneFrames()
        recomputeCanvasBounds()
        if let viewportOrigin {
            setViewportOrigin(viewportOrigin)
        } else {
            clampViewportOrigin()
        }
    }

    private func rebuildStripStateFromPaneFrames() {
        stripState = Self.makeStripState(
            from: panes,
            viewportSize: viewportSize,
            viewportOriginX: viewportOrigin.x,
            paneGap: paneGap
        )
        syncPaneFramesFromStripState()
    }

    private func syncPaneFramesFromStripState() {
        stripState.updateViewportSize(viewportSize)
        let framesByPaneId = stripState.framesByPaneId()
        let paneOrder = Dictionary(uniqueKeysWithValues: stripState.items.enumerated().map { ($1.paneId, $0) })

        panes.sort { lhs, rhs in
            let lhsIndex = paneOrder[lhs.pane.id] ?? Int.max
            let rhsIndex = paneOrder[rhs.pane.id] ?? Int.max
            if lhsIndex != rhsIndex {
                return lhsIndex < rhsIndex
            }
            return lhs.pane.id.id.uuidString < rhs.pane.id.id.uuidString
        }

        for placement in panes {
            guard let stripFrame = framesByPaneId[placement.pane.id] else { continue }
            placement.frame = CGRect(
                x: stripFrame.minX,
                y: placement.frame.minY,
                width: stripFrame.width,
                height: placement.frame.height
            ).integral
        }

        viewportOrigin.x = stripState.viewportOriginX
    }

    private func paneId(matching targetFrame: CGRect) -> PaneID? {
        panes.first { placement in
            abs(placement.frame.minX - targetFrame.minX) <= 1.0
                && abs(placement.frame.width - targetFrame.width) <= 1.0
                && abs(placement.frame.minY - targetFrame.minY) <= 1.0
                && abs(placement.frame.height - targetFrame.height) <= 1.0
        }?.pane.id
    }

    private static func makeStripState(
        from panes: [PaperCanvasPane],
        viewportSize: CGSize,
        viewportOriginX: CGFloat,
        paneGap: CGFloat
    ) -> PaperCanvasStripState {
        let orderedPanes = panes.sorted { lhs, rhs in
            if abs(lhs.frame.minX - rhs.frame.minX) > 0.001 {
                return lhs.frame.minX < rhs.frame.minX
            }
            return lhs.pane.id.id.uuidString < rhs.pane.id.id.uuidString
        }

        var state = PaperCanvasStripState(
            items: orderedPanes.map { .init(paneId: $0.pane.id, width: $0.frame.width) },
            viewportSize: viewportSize,
            viewportOriginX: viewportOriginX,
            paneGap: paneGap
        )
        state.updateViewportSize(viewportSize)
        state.setViewportOriginX(viewportOriginX)
        return state
    }

    @discardableResult
    func resizePane(
        _ paneId: PaneID,
        direction: NavigationDirection,
        amount: CGFloat,
        minimumSize: CGSize
    ) -> CGRect? {
        guard amount > 0,
              let target = pane(paneId) else {
            return nil
        }

        var newFrame = target.frame
        switch direction {
        case .left:
            newFrame.origin.x -= amount
            newFrame.size.width += amount
        case .right:
            newFrame.size.width += amount
        case .up:
            newFrame.origin.y -= amount
            newFrame.size.height += amount
        case .down:
            newFrame.size.height += amount
        }

        newFrame.size.width = max(newFrame.size.width, minimumSize.width)
        newFrame.size.height = max(newFrame.size.height, minimumSize.height)
        target.frame = newFrame.integral

        switch direction {
        case .left:
            shiftCollisions(
                startingFrames: [target.frame],
                orientation: .horizontal,
                insertFirst: true,
                delta: amount,
                excluding: paneId
            )
        case .right:
            shiftCollisions(
                startingFrames: [target.frame],
                orientation: .horizontal,
                insertFirst: false,
                delta: amount,
                excluding: paneId
            )
        case .up:
            shiftCollisions(
                startingFrames: [target.frame],
                orientation: .vertical,
                insertFirst: true,
                delta: amount,
                excluding: paneId
            )
        case .down:
            shiftCollisions(
                startingFrames: [target.frame],
                orientation: .vertical,
                insertFirst: false,
                delta: amount,
                excluding: paneId
            )
        }

        rebuildStripStateFromPaneFrames()
        recomputeCanvasBounds()
        guard let resolvedFrame = pane(paneId)?.frame else {
            return nil
        }
        reveal(resolvedFrame)
        return resolvedFrame
    }

    func resolvedSplitPlacement(
        for targetFrame: CGRect,
        orientation: SplitOrientation,
        insertFirst: Bool,
        minimumSize: CGSize
    ) -> SplitPlacement {
        if let localPlacement = localSplitPlacement(
            for: targetFrame,
            orientation: orientation,
            insertFirst: insertFirst,
            minimumSize: minimumSize
        ) {
            return localPlacement
        }

        let translated = adjacentFrame(for: targetFrame, orientation: orientation, insertFirst: insertFirst)
        let overflowFrame = resolveCollisions(for: translated, orientation: orientation, insertFirst: insertFirst)
        return SplitPlacement(
            existingFrame: targetFrame.integral,
            newFrame: overflowFrame,
            mode: .canvasOverflow
        )
    }

    private func adjacentFrame(
        for targetFrame: CGRect,
        orientation: SplitOrientation,
        insertFirst: Bool
    ) -> CGRect {
        switch orientation {
        case .horizontal:
            return CGRect(
                x: insertFirst ? targetFrame.minX - targetFrame.width - paneGap : targetFrame.maxX + paneGap,
                y: targetFrame.minY,
                width: targetFrame.width,
                height: targetFrame.height
            )
        case .vertical:
            return CGRect(
                x: targetFrame.minX,
                y: insertFirst ? targetFrame.minY - targetFrame.height - paneGap : targetFrame.maxY + paneGap,
                width: targetFrame.width,
                height: targetFrame.height
            )
        }
    }

    private func resolveCollisions(
        for proposedFrame: CGRect,
        orientation: SplitOrientation,
        insertFirst: Bool
    ) -> CGRect {
        let shiftDistance = orientation == .horizontal
            ? proposedFrame.width + paneGap
            : proposedFrame.height + paneGap
        shiftCollisions(
            startingFrames: [proposedFrame],
            orientation: orientation,
            insertFirst: insertFirst,
            delta: shiftDistance
        )
        recomputeCanvasBounds()
        return proposedFrame.integral
    }

    private func localSplitPlacement(
        for targetFrame: CGRect,
        orientation: SplitOrientation,
        insertFirst: Bool,
        minimumSize: CGSize
    ) -> SplitPlacement? {
        switch orientation {
        case .horizontal:
            let availableWidth = targetFrame.width - paneGap
            guard availableWidth >= minimumSize.width * 2 else {
                return nil
            }

            let firstWidth = floor(availableWidth / 2)
            let secondWidth = availableWidth - firstWidth
            guard firstWidth >= minimumSize.width,
                  secondWidth >= minimumSize.width else {
                return nil
            }

            let leftFrame = CGRect(
                x: targetFrame.minX,
                y: targetFrame.minY,
                width: firstWidth,
                height: targetFrame.height
            ).integral
            let rightFrame = CGRect(
                x: leftFrame.maxX + paneGap,
                y: targetFrame.minY,
                width: secondWidth,
                height: targetFrame.height
            ).integral

            return SplitPlacement(
                existingFrame: insertFirst ? rightFrame : leftFrame,
                newFrame: insertFirst ? leftFrame : rightFrame,
                mode: .localReflow
            )

        case .vertical:
            let availableHeight = targetFrame.height - paneGap
            guard availableHeight >= minimumSize.height * 2 else {
                return nil
            }

            let firstHeight = floor(availableHeight / 2)
            let secondHeight = availableHeight - firstHeight
            guard firstHeight >= minimumSize.height,
                  secondHeight >= minimumSize.height else {
                return nil
            }

            let topFrame = CGRect(
                x: targetFrame.minX,
                y: targetFrame.minY,
                width: targetFrame.width,
                height: firstHeight
            ).integral
            let bottomFrame = CGRect(
                x: targetFrame.minX,
                y: topFrame.maxY + paneGap,
                width: targetFrame.width,
                height: secondHeight
            ).integral

            return SplitPlacement(
                existingFrame: insertFirst ? bottomFrame : topFrame,
                newFrame: insertFirst ? topFrame : bottomFrame,
                mode: .localReflow
            )
        }
    }

    private func shiftCollisions(
        startingFrames: [CGRect],
        orientation: SplitOrientation,
        insertFirst: Bool,
        delta: CGFloat,
        excluding excludedPaneId: PaneID? = nil
    ) {
        let signedDelta = delta * (insertFirst ? -1 : 1)
        let offset = orientation == .horizontal
            ? CGSize(width: signedDelta, height: 0)
            : CGSize(width: 0, height: signedDelta)

        var queue = startingFrames
        var shiftedPaneIds = Set<PaneID>()
        if let excludedPaneId {
            shiftedPaneIds.insert(excludedPaneId)
        }

        while let collisionFrame = queue.popLast() {
            let overlapping = panes.filter { placement in
                if shiftedPaneIds.contains(placement.pane.id) {
                    return false
                }

                switch orientation {
                case .horizontal:
                    let overlapsLane = placement.frame.maxY > collisionFrame.minY && placement.frame.minY < collisionFrame.maxY
                    let isInTravelDirection = insertFirst
                        ? placement.frame.minX <= collisionFrame.maxX
                        : placement.frame.maxX >= collisionFrame.minX
                    return overlapsLane
                        && isInTravelDirection
                        && placement.frame.intersects(collisionFrame.insetBy(dx: -paneGap / 2, dy: 0))
                case .vertical:
                    let overlapsLane = placement.frame.maxX > collisionFrame.minX && placement.frame.minX < collisionFrame.maxX
                    let isInTravelDirection = insertFirst
                        ? placement.frame.minY <= collisionFrame.maxY
                        : placement.frame.maxY >= collisionFrame.minY
                    return overlapsLane
                        && isInTravelDirection
                        && placement.frame.intersects(collisionFrame.insetBy(dx: 0, dy: -paneGap / 2))
                }
            }

            guard !overlapping.isEmpty else { continue }
            for placement in overlapping {
                shiftedPaneIds.insert(placement.pane.id)
                placement.frame = placement.frame.offsetBy(dx: offset.width, dy: offset.height).integral
                queue.append(placement.frame)
            }
        }
    }
}
