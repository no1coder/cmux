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

    var showsLeftOverflowHint: Bool {
        viewportOriginX > 0.5
    }

    var showsRightOverflowHint: Bool {
        viewportOriginX + viewportSize.width < totalCanvasWidth() - 0.5
    }

    static func bootstrap(paneId: PaneID, viewportSize: CGSize, paneGap: CGFloat) -> Self {
        Self(
            items: [.init(paneId: paneId, width: viewportSize.width)],
            viewportSize: viewportSize,
            viewportOriginX: 0,
            paneGap: paneGap
        )
    }

    mutating func updateViewportSize(_ size: CGSize) {
        viewportSize = size
        normalizeSinglePaneWidthIfNeeded()
        clampViewportOriginX()
    }

    mutating func setViewportOriginX(_ originX: CGFloat) {
        viewportOriginX = originX
        clampViewportOriginX()
    }

    mutating func revealPane(_ paneId: PaneID) {
        guard let frame = framesByPaneId()[paneId] else {
            clampViewportOriginX()
            return
        }

        if frame.minX < viewportOriginX {
            viewportOriginX = frame.minX
        } else if frame.maxX > viewportOriginX + viewportSize.width {
            viewportOriginX = frame.maxX - viewportSize.width
        }

        clampViewportOriginX()
    }

    func framesByPaneId() -> [PaneID: CGRect] {
        var result: [PaneID: CGRect] = [:]

        for (paneId, frame) in realizedFrames() {
            result[paneId] = frame
        }

        return result
    }

    mutating func splitRight(_ paneId: PaneID, minimumPaneWidth: CGFloat) -> PaneID? {
        let newPaneId = PaneID()
        guard splitRight(paneId, inserting: newPaneId, minimumPaneWidth: minimumPaneWidth) else {
            return nil
        }
        return newPaneId
    }

    mutating func splitRight(
        _ paneId: PaneID,
        inserting newPaneId: PaneID,
        minimumPaneWidth: CGFloat
    ) -> Bool {
        normalizeSinglePaneWidthIfNeeded()

        guard let index = items.firstIndex(where: { $0.paneId == paneId }) else {
            return false
        }

        let availableWidth = items[index].width - paneGap
        let leftWidth = floor(availableWidth / 2)
        let rightWidth = availableWidth - leftWidth
        guard leftWidth >= minimumPaneWidth, rightWidth >= minimumPaneWidth else {
            return false
        }

        items[index].width = leftWidth
        items.insert(.init(paneId: newPaneId, width: rightWidth), at: index + 1)
        clampViewportOriginX()
        return true
    }

    mutating func openPaneRight(
        after paneId: PaneID,
        requestedWidth: CGFloat,
        minimumPaneWidth: CGFloat
    ) -> PaneID {
        if let newPaneId = openPaneRightIfPresent(
            after: paneId,
            requestedWidth: requestedWidth,
            minimumPaneWidth: minimumPaneWidth
        ) {
            return newPaneId
        }

        normalizeSinglePaneWidthIfNeeded()

        let newPaneId = PaneID()
        let width = max(requestedWidth, minimumPaneWidth)
        items.append(.init(paneId: newPaneId, width: width))
        revealRightEdge(of: newPaneId)
        return newPaneId
    }

    mutating func openPaneRightIfPresent(
        after paneId: PaneID,
        requestedWidth: CGFloat,
        minimumPaneWidth: CGFloat
    ) -> PaneID? {
        let newPaneId = PaneID()
        guard openPaneRightIfPresent(
            after: paneId,
            inserting: newPaneId,
            requestedWidth: requestedWidth,
            minimumPaneWidth: minimumPaneWidth
        ) else {
            return nil
        }
        return newPaneId
    }

    mutating func openPaneRightIfPresent(
        after paneId: PaneID,
        inserting newPaneId: PaneID,
        requestedWidth: CGFloat,
        minimumPaneWidth: CGFloat
    ) -> Bool {
        normalizeSinglePaneWidthIfNeeded()

        let width = max(requestedWidth, minimumPaneWidth)
        guard let targetIndex = items.firstIndex(where: { $0.paneId == paneId }) else {
            return false
        }

        let insertIndex = targetIndex + 1
        items.insert(.init(paneId: newPaneId, width: width), at: insertIndex)
        revealRightEdge(of: newPaneId)
        return true
    }

    @discardableResult
    mutating func closePane(_ paneId: PaneID, preferredFocus: PaneID?) -> PaneID? {
        normalizeSinglePaneWidthIfNeeded()

        guard let index = items.firstIndex(where: { $0.paneId == paneId }) else {
            return nil
        }

        let leftNeighbor = index > 0 ? items[index - 1].paneId : nil
        let rightNeighbor = index + 1 < items.count ? items[index + 1].paneId : nil
        items.remove(at: index)
        clampViewportOriginX()

        if let preferredFocus,
           preferredFocus != paneId,
           items.contains(where: { $0.paneId == preferredFocus }) {
            return preferredFocus
        }

        return leftNeighbor ?? rightNeighbor ?? items.first?.paneId
    }

    private func normalizedItems() -> [PaperCanvasStripItem] {
        guard items.count == 1, viewportSize.width > 0, let onlyItem = items.first else {
            return items
        }

        return [.init(paneId: onlyItem.paneId, width: viewportSize.width)]
    }

    private mutating func normalizeSinglePaneWidthIfNeeded() {
        guard items.count == 1, viewportSize.width > 0 else {
            return
        }

        items[0].width = viewportSize.width
    }

    private mutating func clampViewportOriginX() {
        let canvasWidth = totalCanvasWidth()
        let maxOriginX = max(0, canvasWidth - viewportSize.width)
        viewportOriginX = min(max(viewportOriginX, 0), maxOriginX)
    }

    private mutating func revealRightEdge(of paneId: PaneID) {
        revealPane(paneId)
    }

    private func totalCanvasWidth() -> CGFloat {
        realizedFrames().map(\.1.maxX).max() ?? viewportSize.width
    }

    private func resolvedFocus(afterRemoving _: PaneID?, preferredFocus: PaneID?) -> PaneID? {
        if let preferredFocus,
           items.contains(where: { $0.paneId == preferredFocus }) {
            return preferredFocus
        }

        return items.first?.paneId
    }

    private func realizedFrames() -> [(PaneID, CGRect)] {
        var nextX: CGFloat = 0
        return normalizedItems().map { item in
            let frame = CGRect(
                x: nextX,
                y: 0,
                width: item.width,
                height: viewportSize.height
            ).integral
            nextX = frame.maxX + paneGap
            return (item.paneId, frame)
        }
    }
}
