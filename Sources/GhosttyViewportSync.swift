struct GhosttyScrollbar {
    let total: UInt64
    let offset: UInt64
    let len: UInt64

    init(total: Int, offset: Int, len: Int) {
        self.total = UInt64(max(0, total))
        self.offset = UInt64(max(0, offset))
        self.len = UInt64(max(0, len))
    }

    var totalRows: Int { Int(min(total, UInt64(Int.max))) }
    var offsetRows: Int { Int(min(offset, UInt64(Int.max))) }
    var visibleRows: Int { Int(min(len, UInt64(Int.max))) }
    var maxTopVisibleRow: Int { max(0, totalRows - visibleRows) }
    var incomingTopVisibleRow: Int {
        max(0, min(maxTopVisibleRow, maxTopVisibleRow - offsetRows))
    }
}

struct GhosttyScrollViewportSyncPlan: Equatable {
    let targetTopVisibleRow: Int
    let targetRowFromBottom: Int
    let storedTopVisibleRow: Int?
}

enum GhosttyViewportChangeSource {
    case userInteraction
    case internalCorrection
}

enum GhosttyViewportInteraction {
    case scrollWheel
    case bindingAction(action: String, source: GhosttyViewportChangeSource)
}

struct GhosttyScrollCorrectionDispatchState: Equatable {
    let lastSentRow: Int?
    let pendingAnchorCorrectionRow: Int?
}

struct GhosttyExplicitViewportChangeConsumption: Equatable {
    let isExplicitViewportChange: Bool
    let remainingPendingExplicitViewportChange: Bool
}

func ghosttyScrollViewportSyncPlan(
    scrollbar: GhosttyScrollbar,
    storedTopVisibleRow: Int?,
    isExplicitViewportChange: Bool
) -> GhosttyScrollViewportSyncPlan {
    let targetTopVisibleRow: Int
    if isExplicitViewportChange {
        targetTopVisibleRow = scrollbar.incomingTopVisibleRow
    } else if let storedTopVisibleRow {
        targetTopVisibleRow = max(0, min(storedTopVisibleRow, scrollbar.maxTopVisibleRow))
    } else {
        targetTopVisibleRow = scrollbar.incomingTopVisibleRow
    }
    let targetRowFromBottom = max(0, scrollbar.maxTopVisibleRow - targetTopVisibleRow)
    return GhosttyScrollViewportSyncPlan(
        targetTopVisibleRow: targetTopVisibleRow,
        targetRowFromBottom: targetRowFromBottom,
        storedTopVisibleRow: targetRowFromBottom > 0 ? targetTopVisibleRow : nil
    )
}

func ghosttyBindingActionMutatesViewport(_ action: String) -> Bool {
    action.hasPrefix("scroll_") ||
        action.hasPrefix("jump_to_prompt:") ||
        action == "search:next" ||
        action == "search:previous" ||
        action == "navigate_search:next" ||
        action == "navigate_search:previous"
}

func ghosttyShouldMarkExplicitViewportChange(
    action: String,
    source: GhosttyViewportChangeSource
) -> Bool {
    guard source == .userInteraction else { return false }
    return ghosttyBindingActionMutatesViewport(action)
}

func ghosttyShouldBeginExplicitViewportChange(
    for interaction: GhosttyViewportInteraction
) -> Bool {
    switch interaction {
    case .scrollWheel:
        return true
    case let .bindingAction(action, source):
        return ghosttyShouldMarkExplicitViewportChange(action: action, source: source)
    }
}

func ghosttyConsumeExplicitViewportChange(
    pendingExplicitViewportChange: Bool
) -> GhosttyExplicitViewportChangeConsumption {
    GhosttyExplicitViewportChangeConsumption(
        isExplicitViewportChange: pendingExplicitViewportChange,
        remainingPendingExplicitViewportChange: false
    )
}

func ghosttyScrollCorrectionDispatchState(
    previousLastSentRow: Int?,
    previousPendingAnchorCorrectionRow: Int?,
    targetRowFromBottom: Int,
    dispatchSucceeded: Bool
) -> GhosttyScrollCorrectionDispatchState {
    guard dispatchSucceeded else {
        return GhosttyScrollCorrectionDispatchState(
            lastSentRow: previousLastSentRow,
            pendingAnchorCorrectionRow: previousPendingAnchorCorrectionRow
        )
    }

    return GhosttyScrollCorrectionDispatchState(
        lastSentRow: targetRowFromBottom,
        pendingAnchorCorrectionRow: targetRowFromBottom
    )
}
