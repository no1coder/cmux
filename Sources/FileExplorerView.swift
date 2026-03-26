import AppKit
import Bonsplit
import Combine
import SwiftUI

// MARK: - Container View

struct FileExplorerView: View {
    @ObservedObject var store: FileExplorerStore
    @ObservedObject var state: FileExplorerState

    var body: some View {
        VStack(spacing: 0) {
            if store.rootPath.isEmpty {
                emptyState
            } else {
                fileTree
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 28))
                .foregroundColor(.secondary)
            Text(String(localized: "fileExplorer.empty", defaultValue: "No folder open"))
                .font(.system(size: 13))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fileTree: some View {
        VStack(alignment: .leading, spacing: 0) {
            rootPathHeader
            if store.isRootLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                FileExplorerOutlineView(store: store)
            }
        }
    }

    private var rootPathHeader: some View {
        HStack(spacing: 4) {
            Image(systemName: "folder.fill")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Text(store.displayRootPath)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - NSOutlineView Wrapper

struct FileExplorerOutlineView: NSViewRepresentable {
    @ObservedObject var store: FileExplorerStore

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let outlineView = NSOutlineView()
        outlineView.headerView = nil
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.style = .sourceList
        outlineView.selectionHighlightStyle = .sourceList
        outlineView.rowSizeStyle = .default
        outlineView.indentationPerLevel = 16
        outlineView.autoresizesOutlineColumn = true
        outlineView.floatsGroupRows = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.isEditable = false
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        outlineView.dataSource = context.coordinator
        outlineView.delegate = context.coordinator

        scrollView.documentView = outlineView
        context.coordinator.outlineView = outlineView

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.store = store
        context.coordinator.reloadIfNeeded()
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var store: FileExplorerStore
        weak var outlineView: NSOutlineView?
        private var lastRootNodeCount: Int = -1
        private var observationCancellable: AnyCancellable?

        init(store: FileExplorerStore) {
            self.store = store
            super.init()
            observeStore()
        }

        private func observeStore() {
            observationCancellable = store.objectWillChange
                .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
                .sink { [weak self] _ in
                    self?.reloadIfNeeded()
                }
        }

        func reloadIfNeeded() {
            guard let outlineView else { return }
            let newCount = store.rootNodes.count
            if newCount != lastRootNodeCount {
                lastRootNodeCount = newCount
                let expandedPaths = store.expandedPaths
                outlineView.reloadData()
                restoreExpansionState(expandedPaths, in: outlineView)
            } else {
                refreshLoadedNodes(in: outlineView)
            }
        }

        private func restoreExpansionState(_ expandedPaths: Set<String>, in outlineView: NSOutlineView) {
            for row in 0..<outlineView.numberOfRows {
                guard let node = outlineView.item(atRow: row) as? FileExplorerNode else { continue }
                if expandedPaths.contains(node.path) && outlineView.isExpandable(node) {
                    outlineView.expandItem(node)
                }
            }
        }

        private func refreshLoadedNodes(in outlineView: NSOutlineView) {
            for row in 0..<outlineView.numberOfRows {
                guard let node = outlineView.item(atRow: row) as? FileExplorerNode else { continue }
                if node.isDirectory {
                    let isCurrentlyExpanded = outlineView.isItemExpanded(node)
                    let shouldBeExpanded = store.expandedPaths.contains(node.path)

                    if shouldBeExpanded && !isCurrentlyExpanded && node.children != nil {
                        outlineView.reloadItem(node, reloadChildren: true)
                        outlineView.expandItem(node)
                    } else if !shouldBeExpanded && isCurrentlyExpanded {
                        outlineView.collapseItem(node)
                    } else if node.children != nil {
                        outlineView.reloadItem(node, reloadChildren: true)
                        if shouldBeExpanded {
                            outlineView.expandItem(node)
                        }
                    }
                }
            }
        }

        // MARK: - NSOutlineViewDataSource

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            if item == nil {
                return store.rootNodes.count
            }
            guard let node = item as? FileExplorerNode else { return 0 }
            return node.sortedChildren?.count ?? 0
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            if item == nil {
                return store.rootNodes[index]
            }
            guard let node = item as? FileExplorerNode,
                  let children = node.sortedChildren else {
                return FileExplorerNode(name: "", path: "", isDirectory: false)
            }
            return children[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let node = item as? FileExplorerNode else { return false }
            return node.isExpandable
        }

        // MARK: - NSOutlineViewDelegate

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? FileExplorerNode else { return nil }

            let identifier = NSUserInterfaceItemIdentifier("FileExplorerCell")
            let cellView: FileExplorerCellView
            if let existing = outlineView.makeView(withIdentifier: identifier, owner: nil) as? FileExplorerCellView {
                cellView = existing
            } else {
                cellView = FileExplorerCellView(identifier: identifier)
            }

            cellView.configure(with: node)
            cellView.onHover = { [weak self] isHovering in
                guard let self else { return }
                if isHovering {
                    Task { @MainActor in
                        self.store.prefetchChildren(for: node)
                    }
                } else {
                    Task { @MainActor in
                        self.store.cancelPrefetch(for: node)
                    }
                }
            }

            return cellView
        }

        func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
            guard let node = item as? FileExplorerNode, node.isDirectory else { return false }
            Task { @MainActor in
                store.expand(node: node)
            }
            return node.children != nil
        }

        func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
            guard let node = item as? FileExplorerNode else { return false }
            Task { @MainActor in
                store.collapse(node: node)
            }
            return true
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            guard let node = notification.userInfo?["NSObject"] as? FileExplorerNode else { return }
            Task { @MainActor in
                if !store.isExpanded(node) {
                    store.expand(node: node)
                }
            }
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard let node = notification.userInfo?["NSObject"] as? FileExplorerNode else { return }
            Task { @MainActor in
                if store.isExpanded(node) {
                    store.collapse(node: node)
                }
            }
        }

        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
            FileExplorerRowView()
        }

        func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
            22
        }
    }
}

// MARK: - Cell View

final class FileExplorerCellView: NSTableCellView {
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let loadingIndicator = NSProgressIndicator()
    private var trackingArea: NSTrackingArea?
    var onHover: ((Bool) -> Void)?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1

        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .small
        loadingIndicator.isHidden = true

        addSubview(iconView)
        addSubview(nameLabel)
        addSubview(loadingIndicator)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 4),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: loadingIndicator.leadingAnchor, constant: -4),

            loadingIndicator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            loadingIndicator.centerYAnchor.constraint(equalTo: centerYAnchor),
            loadingIndicator.widthAnchor.constraint(equalToConstant: 12),
            loadingIndicator.heightAnchor.constraint(equalToConstant: 12),
        ])
    }

    func configure(with node: FileExplorerNode) {
        nameLabel.stringValue = node.name

        if node.isDirectory {
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            iconView.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
            iconView.contentTintColor = .systemBlue
        } else {
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            iconView.image = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
            iconView.contentTintColor = .secondaryLabelColor
        }

        if node.isLoading {
            loadingIndicator.isHidden = false
            loadingIndicator.startAnimation(nil)
        } else {
            loadingIndicator.isHidden = true
            loadingIndicator.stopAnimation(nil)
        }

        if let error = node.error {
            nameLabel.textColor = .systemRed
            nameLabel.toolTip = error
        } else {
            nameLabel.textColor = .labelColor
            nameLabel.toolTip = node.path
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(false)
    }
}

// MARK: - Row View (Finder-like rounded inset)

final class FileExplorerRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let insetRect = bounds.insetBy(dx: 4, dy: 1)
        let path = NSBezierPath(roundedRect: insetRect, xRadius: 4, yRadius: 4)
        NSColor.controlAccentColor.withAlphaComponent(0.2).setFill()
        path.fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        isSelected ? .emphasized : .normal
    }
}

// MARK: - Right Titlebar Toggle Button

struct FileExplorerTitlebarButton: View {
    let onToggle: () -> Void
    let config: TitlebarControlsStyleConfig
    @State private var isHovering = false

    var body: some View {
        TitlebarControlButton(config: config, action: {
            #if DEBUG
            dlog("titlebar.toggleFileExplorer")
            #endif
            onToggle()
        }) {
            Image(systemName: "sidebar.right")
                .font(.system(size: config.iconSize))
                .frame(width: config.buttonSize, height: config.buttonSize)
        }
        .accessibilityIdentifier("titlebarControl.toggleFileExplorer")
        .accessibilityLabel(String(localized: "titlebar.fileExplorer.accessibilityLabel", defaultValue: "Toggle File Explorer"))
        .safeHelp(KeyboardShortcutSettings.Action.toggleFileExplorer.tooltip(
            String(localized: "titlebar.fileExplorer.tooltip", defaultValue: "Show or hide the file explorer")
        ))
    }
}

// MARK: - Right Titlebar Accessory ViewController

final class FileExplorerTitlebarAccessoryViewController: NSTitlebarAccessoryViewController {
    private let hostingView: NonDraggableHostingView<FileExplorerTitlebarButton>
    private let containerView = NSView()
    private var didInitialLayout = false

    init(onToggle: @escaping () -> Void) {
        let style = TitlebarControlsStyle(rawValue: UserDefaults.standard.integer(forKey: "titlebarControlsStyle")) ?? .classic
        hostingView = NonDraggableHostingView(
            rootView: FileExplorerTitlebarButton(
                onToggle: onToggle,
                config: style.config
            )
        )

        super.init(nibName: nil, bundle: nil)

        view = containerView
        containerView.translatesAutoresizingMaskIntoConstraints = true
        containerView.wantsLayer = true
        containerView.layer?.masksToBounds = false
        hostingView.translatesAutoresizingMaskIntoConstraints = true
        containerView.addSubview(hostingView)

        // Compute initial size once from the hosting view's fitting size
        hostingView.layoutSubtreeIfNeeded()
        let fitting = hostingView.fittingSize
        let width = fitting.width + 8
        let height = max(fitting.height, 28)
        preferredContentSize = NSSize(width: width, height: height)
        containerView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let yOffset = max(0, (height - fitting.height) / 2.0)
        hostingView.frame = NSRect(x: 0, y: yOffset, width: fitting.width, height: fitting.height)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !didInitialLayout else { return }
        didInitialLayout = true
        // Re-measure once after attached to window (titlebar height is now known)
        let fitting = hostingView.fittingSize
        guard fitting.width > 0, fitting.height > 0 else { return }
        let titlebarHeight: CGFloat = {
            if let window = view.window,
               let closeButton = window.standardWindowButton(.closeButton),
               let titlebarView = closeButton.superview,
               titlebarView.frame.height > 0 {
                return titlebarView.frame.height
            }
            return fitting.height
        }()
        let containerHeight = max(fitting.height, titlebarHeight)
        let yOffset = max(0, (containerHeight - fitting.height) / 2.0)
        let width = fitting.width + 8
        preferredContentSize = NSSize(width: width, height: containerHeight)
        containerView.frame = NSRect(x: 0, y: 0, width: width, height: containerHeight)
        hostingView.frame = NSRect(x: 0, y: yOffset, width: fitting.width, height: fitting.height)
    }
}
