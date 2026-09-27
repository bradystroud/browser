import AppKit

/// Hosts one Settings pane as an NSTabViewItem's view, so a pane is never
/// squeezed below the height its content needs: once the window is shorter
/// than that, the pane scrolls vertically instead of clipping or overlapping.
///
/// The document view always spans the full clip width (there is no
/// horizontal scrolling) and is `max(pane content height, clip height)`
/// tall, so a pane with room to spare still stretches exactly as it did
/// when NSTabView sized it directly, and the scroller -- auto-hidden --
/// only appears when the content genuinely doesn't fit.
final class SettingsPaneScrollView: NSScrollView {
    private let pane: SettingsPaneController
    private let documentContainer = SettingsPaneDocumentView()
    /// Resizing the document view re-tiles the scroll view (a scroller may
    /// appear or vanish), which lands back in tile(); this breaks that loop.
    private var isUpdatingDocumentFrame = false

    init(pane: SettingsPaneController) {
        self.pane = pane
        super.init(frame: NSRect(origin: .zero, size: pane.view.frame.size))
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        horizontalScrollElasticity = .none
        drawsBackground = false
        borderType = .noBorder

        documentContainer.frame = NSRect(origin: .zero, size: pane.view.frame.size)
        pane.view.frame = documentContainer.bounds
        pane.view.autoresizingMask = [.width, .height]
        documentContainer.addSubview(pane.view)
        documentView = documentContainer
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func tile() {
        super.tile()
        updateDocumentFrame()
    }

    /// Re-measures the pane -- call after anything that changes how tall its
    /// content is, such as a help label's text.
    func paneContentHeightDidChange() {
        updateDocumentFrame()
    }

    private func updateDocumentFrame() {
        guard !isUpdatingDocumentFrame else { return }
        isUpdatingDocumentFrame = true
        defer { isUpdatingDocumentFrame = false }

        let visible = contentView.frame.size
        let contentHeight = pane.preferredContentHeight(forWidth: visible.width)
        let size = NSSize(width: visible.width, height: max(contentHeight, visible.height).rounded(.up))
        if documentContainer.frame.size != size {
            documentContainer.setFrameSize(size)
        }
    }
}

/// Flipped so the pane stays pinned to the top of the scroll view: extra
/// height collects at the bottom and scrolling starts at the first row.
private final class SettingsPaneDocumentView: NSView {
    override var isFlipped: Bool { true }
}

extension SettingsPaneController {
    /// Tells the hosting SettingsPaneScrollView the pane's content height may
    /// have changed, so it can grow or shrink the scrollable area to match.
    func invalidateContentHeight() {
        (view.enclosingScrollView as? SettingsPaneScrollView)?.paneContentHeightDidChange()
    }
}
