import AppKit

/// A violet strip across the top of every window an agent opened with
/// `browser page open`, so the user can always tell an agent's window from
/// their own: which page id the agent knows it by, what it did last, and
/// whether it is recording.
///
/// It sits inside contentView like the dev-build strip (directly below it
/// when both show), because that is the only place NSGlassEffectView
/// guarantees a z-order, and the window's chrome is laid out below it rather
/// than under it, so it never covers the page. Screenshots and recordings
/// capture only the page, so the strip never appears in them.
final class AgentWindowIndicatorView: NSView {
    static let height: CGFloat = 22

    private static let leadingInset: CGFloat = 10
    private static let trailingInset: CGFloat = 10

    private let label = NSTextField(labelWithString: "")
    private let recordingLabel = NSTextField(labelWithString: "● REC")

    private var pageId: String?
    private var activity: String?

    var isRecording = false {
        didSet {
            recordingLabel.isHidden = !isRecording
            refresh()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Fixed, not dynamic: the same in light and dark mode, and unlike the
        // amber dev-build strip and any system chrome.
        layer?.backgroundColor = NSColor(srgbRed: 0.42, green: 0.30, blue: 0.93, alpha: 1).cgColor
        toolTip = "An agent controls this window through the browser command-line tool. It never takes your keyboard, and it cannot reach your other windows."

        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        label.autoresizingMask = [.width]
        addSubview(label)

        recordingLabel.font = .systemFont(ofSize: 11, weight: .bold)
        recordingLabel.textColor = NSColor(srgbRed: 1.0, green: 0.55, blue: 0.55, alpha: 1)
        recordingLabel.isHidden = true
        recordingLabel.autoresizingMask = [.minXMargin]
        addSubview(recordingLabel)

        layoutLabels()
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(pageId: String) {
        self.pageId = pageId
        refresh()
    }

    /// What the agent is doing or last did, e.g. "click e15".
    func update(activity: String) {
        self.activity = activity
        refresh()
    }

    private func refresh() {
        var parts = ["AGENT"]
        if let pageId { parts.append(pageId) }
        parts.append(activity ?? "controlled by the browser CLI")
        label.stringValue = parts.joined(separator: " · ")
        setAccessibilityLabel("Agent window: " + label.stringValue + (isRecording ? ", recording" : ""))
        layoutLabels()
    }

    private func layoutLabels() {
        let recordingSize = recordingLabel.intrinsicContentSize
        recordingLabel.frame = NSRect(
            x: bounds.width - Self.trailingInset - recordingSize.width,
            y: (bounds.height - recordingSize.height) / 2,
            width: recordingSize.width, height: recordingSize.height)
        let reserved = isRecording ? recordingSize.width + Self.trailingInset + 8 : Self.trailingInset
        let height = label.intrinsicContentSize.height
        label.frame = NSRect(
            x: Self.leadingInset, y: (bounds.height - height) / 2,
            width: max(0, bounds.width - Self.leadingInset - reserved), height: height)
    }

    /// The strip covers part of the hidden titlebar's drag area, so a drag on
    /// it still moves the window.
    override var mouseDownCanMoveWindow: Bool { true }
}
