import AppKit

/// A violet strip across the top of every window an agent opened with
/// `browser page open`, so the user can always tell an agent's window from
/// their own: which agent it is (its tool, session name and model, as the
/// CLI found them), which page id it knows the window by, what it did last,
/// and whether it is recording. Its Stop button lets the user halt the agent in
/// this window at once (`AgentPages.setStoppedByUser`); the strip turns red
/// while it is stopped.
///
/// It sits inside contentView like the dev-build strip (directly below it
/// when both show), because that is the only place NSGlassEffectView
/// guarantees a z-order, and the window's chrome is laid out below it rather
/// than under it, so it never covers the page. Screenshots and recordings
/// capture only the page, so the strip never appears in them.
final class AgentWindowIndicatorView: NSView {
    static let height: CGFloat = 30

    private static let leadingInset: CGFloat = 10
    private static let trailingInset: CGFloat = 6
    private static let spacing: CGFloat = 10

    // Fixed, not dynamic: the same in light and dark mode, and unlike the
    // amber dev-build strip and any system chrome.
    private static let runningColor = NSColor(srgbRed: 0.42, green: 0.30, blue: 0.93, alpha: 1)
    private static let stoppedColor = NSColor(srgbRed: 0.62, green: 0.10, blue: 0.10, alpha: 1)
    private static let stopButtonColor = NSColor(srgbRed: 0.86, green: 0.13, blue: 0.13, alpha: 1)

    private let label = NSTextField(labelWithString: "")
    private let recordingLabel = NSTextField(labelWithString: "● REC")
    private let stopButton = FirstClickButton(title: "", target: nil, action: nil)

    private var pageId: String?
    private var activity: String?
    private var agentTool: String?
    private var agentName: String?
    private var agentModel: String?

    /// Called when the user clicks Stop (true) or Resume (false).
    var onStopChange: ((Bool) -> Void)?

    var isRecording = false {
        didSet {
            recordingLabel.isHidden = !isRecording
            refresh()
        }
    }

    private(set) var isStopped = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        addSubview(label)

        recordingLabel.font = .systemFont(ofSize: 12, weight: .bold)
        recordingLabel.textColor = NSColor(srgbRed: 1.0, green: 0.55, blue: 0.55, alpha: 1)
        recordingLabel.isHidden = true
        addSubview(recordingLabel)

        stopButton.isBordered = false
        stopButton.wantsLayer = true
        stopButton.layer?.cornerRadius = 6
        stopButton.layer?.borderWidth = 1
        stopButton.target = self
        stopButton.action = #selector(toggleStop)
        addSubview(stopButton)

        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(pageId: String) {
        self.pageId = pageId
        refresh()
    }

    /// Fields the CLI could not find stay as they were, so a command run
    /// from somewhere without them never blanks what an earlier one set.
    func update(agentTool: String?, name: String?, model: String?) {
        guard agentTool != nil || name != nil || model != nil else { return }
        if let agentTool { self.agentTool = agentTool }
        if let name { agentName = name }
        if let model { agentModel = model }
        refresh()
    }

    /// What the agent is doing or last did, e.g. "click e15".
    func update(activity: String) {
        self.activity = activity
        refresh()
    }

    func setStopped(_ stopped: Bool) {
        isStopped = stopped
        activity = nil
        refresh()
    }

    @objc private func toggleStop() {
        onStopChange?(!isStopped)
    }

    private func refresh() {
        layer?.backgroundColor = (isStopped ? Self.stoppedColor : Self.runningColor).cgColor
        var parts = [isStopped ? "AGENT STOPPED" : "AGENT"]
        let who = [agentTool, agentName.map { "\u{201C}\($0)\u{201D}" }].compactMap { $0 }.joined(separator: " ")
        if !who.isEmpty { parts.append(who) }
        if let agentModel { parts.append(agentModel) }
        if let pageId { parts.append(pageId) }
        if isStopped {
            parts.append(activity.map { "refused \($0)" } ?? "it cannot act in this window until you resume it")
        } else {
            parts.append(activity ?? "controlled by the browser CLI")
        }
        label.stringValue = parts.joined(separator: " · ")
        // The label truncates in a narrow window, so the tooltip repeats it whole.
        toolTip = label.stringValue + "\n\n" + (isStopped
            ? "You stopped the agent in this window. Every command it sends here is refused until you click Resume."
            : "An agent controls this window through the browser command-line tool. It never takes your keyboard, and it cannot reach your other windows. Stop Agent halts it in this window at once.")

        let title = isStopped ? "▶  Resume Agent" : "■  STOP AGENT"
        stopButton.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .heavy),
            .foregroundColor: isStopped ? Self.stoppedColor : NSColor.white,
        ])
        stopButton.layer?.backgroundColor = (isStopped ? NSColor.white : Self.stopButtonColor).cgColor
        stopButton.layer?.borderColor = NSColor.white.withAlphaComponent(isStopped ? 0 : 0.85).cgColor
        stopButton.setAccessibilityLabel(isStopped ? "Resume agent" : "Stop agent")
        setAccessibilityLabel("Agent window: " + label.stringValue + (isRecording ? ", recording" : ""))
        layoutContents()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutContents()
    }

    private func layoutContents() {
        let buttonWidth = max(124, stopButton.attributedTitle.size().width + 28)
        let buttonHeight = bounds.height - 6
        stopButton.frame = NSRect(
            x: bounds.width - Self.trailingInset - buttonWidth, y: (bounds.height - buttonHeight) / 2,
            width: buttonWidth, height: buttonHeight)

        var trailing = stopButton.frame.minX - Self.spacing
        if isRecording {
            let size = recordingLabel.intrinsicContentSize
            recordingLabel.frame = NSRect(
                x: trailing - size.width, y: (bounds.height - size.height) / 2,
                width: size.width, height: size.height)
            trailing = recordingLabel.frame.minX - Self.spacing
        }
        let height = label.intrinsicContentSize.height
        label.frame = NSRect(
            x: Self.leadingInset, y: (bounds.height - height) / 2,
            width: max(0, trailing - Self.leadingInset), height: height)
    }

    /// The strip covers part of the hidden titlebar's drag area, so a drag on
    /// it still moves the window.
    override var mouseDownCanMoveWindow: Bool { true }
}

/// An agent window never becomes key and the app is often in the background,
/// so without this the first click on Stop would only bring the window
/// forward and a second click would be needed to stop the agent.
private final class FirstClickButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
