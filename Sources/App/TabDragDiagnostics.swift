import AppKit

/// Structured diagnostics for tab drag-to-reorder (browser-rhi.6).
///
/// Drag-to-reorder shipped broken and the reason it shipped broken is that a
/// mouse gesture is the one thing this repo's verification protocol can't
/// exercise: build-green, screenshots and desk-checked arithmetic all pass on
/// a feature whose mouse handling never runs once. So rather than guess again,
/// every stage of the gesture records what it saw, and a failed drag is
/// diagnosed by reading which stage is missing.
///
/// Follows AGENTS.md's "Debugging tricky UI bugs" rule: an array of event
/// objects in a local `.json` file, timestamps and ordering preserved, enough
/// state per record to reconstruct the sequence.
///
/// Off unless switched on, and switchable on *without a relaunch* -- the
/// marker file is stat'd at each drag rather than read once at startup,
/// because the person who needs to turn this on is running an installed
/// /Applications build he can't easily pass launch arguments to.
enum TabDragDiagnostics {
    /// `touch` this to start recording; delete it to stop. Sits next to
    /// session.json/profiles.json, so it's scoped by `--profiles-root` the
    /// same way they are and an agent's scratch instance can never write into
    /// the real one's log.
    private static let markerName = "tab-drag-diagnostics.on"
    private static let logName = "tab-drag-diagnostics.json"

    /// Keeps the file bounded: a drag produces one record per mouse-moved
    /// event, so an afternoon of dragging would otherwise grow without limit.
    /// Oldest records are dropped first -- the interesting ones are always
    /// the most recent attempt.
    private static let maxRecords = 400

    private static var records: [[String: Any]] = []
    private static var flushScheduled = false

    private static var directory: String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].path
        return ProfilesRootResolver.sessionAndProfilesMetadataDirectory(
            arguments: CommandLine.arguments, appSupportDirectory: appSupport
        )
    }

    /// Stat'd per call rather than cached -- see the type's own doc comment.
    /// `--drag-diagnostics` is the equivalent for a launch we do control.
    static var isEnabled: Bool {
        if isForcedOnByArgument { return true }
        return FileManager.default.fileExists(atPath: (directory as NSString).appendingPathComponent(markerName))
    }

    private static let isForcedOnByArgument = CommandLine.arguments.contains("--drag-diagnostics")

    /// `--drag-selftest`, cached -- read from `layout()`, which runs often.
    static let isSelfTestRequested = CommandLine.arguments.contains("--drag-selftest")

    static var logPath: String {
        (directory as NSString).appendingPathComponent(logName)
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// `stage` is the whole point of the file: each is a named point in the
    /// gesture, and diagnosis is "which stage stopped appearing". Callers pass
    /// whatever state is meaningful at that stage in `fields`.
    static func record(_ stage: String, _ fields: [String: Any] = [:]) {
        guard isEnabled else { return }
        var entry: [String: Any] = fields
        entry["stage"] = stage
        entry["t"] = timestampFormatter.string(from: Date())
        records.append(entry)
        if records.count > maxRecords {
            records.removeFirst(records.count - maxRecords)
        }
        scheduleFlush()
    }

    /// Coalesced so a drag's worth of mouse-moved records is one write, but
    /// short enough that the file is on disk before the user has finished
    /// saying "it didn't work" -- and crucially it still flushes when the
    /// gesture *stops early*, which is exactly the failure being chased.
    private static func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            flushScheduled = false
            flush()
        }
    }

    private static func flush() {
        guard let data = try? JSONSerialization.data(
            withJSONObject: records, options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? data.write(to: URL(fileURLWithPath: logPath), options: .atomic)
    }

    /// What AppKit's own hit test lands on across a tab pill, recorded without
    /// anyone touching the mouse.
    ///
    /// This is the one question that mattered most and was cheapest to get
    /// wrong by reasoning: a tab pill is a stack of views (the pill, its
    /// NSGlassEffectView, that view's contentView, then a label/image/buttons
    /// inside it), and only some of those forward a mouse-down up the
    /// responder chain to TabButtonView. Calling `hitTest` directly is a plain
    /// function call over the real, live view hierarchy -- no synthetic
    /// events, no UI automation -- so it answers "what would a press here
    /// actually reach?" from a test launch nobody is clicking in.
    ///
    /// `reachesTabButton` walks the hit view's superview chain, which is the
    /// path a mouse event forwarded by NSResponder's default implementation
    /// would take.
    /// One probe per launch, from ordinary layout rather than from a press --
    /// so the "what would a click here reach?" answer is available from a test
    /// launch nobody is clicking in, which is the whole reason this exists.
    private static var hasProbedThisLaunch = false

    /// `hasProbedThisLaunch` is checked before `isEnabled` deliberately: this
    /// runs from layout, and `isEnabled` stats the marker file.
    static func probeHitTestingOnce(button: TabButtonView) {
        guard !hasProbedThisLaunch, isEnabled, button.window != nil, button.bounds.width > 0 else { return }
        hasProbedThisLaunch = true
        probeHitTesting(button: button)
    }

    static func probeHitTesting(button: TabButtonView, fractions: [CGFloat] = [0.08, 0.3, 0.55, 0.85]) {
        guard isEnabled, let contentView = button.window?.contentView else { return }
        var probes: [[String: Any]] = []
        for fraction in fractions {
            let inButton = NSPoint(x: button.bounds.width * fraction, y: button.bounds.midY)
            let inContent = button.convert(inButton, to: contentView)
            let hit = contentView.hitTest(inContent)
            // What the same press would have reached without TabButtonView's
            // own hitTest override -- the pill's raw subview descent.
            let raw = button.hitTestIgnoringOverride(
                button.convert(inButton, to: button.superview)
            )
            probes.append([
                "fraction": fraction,
                "hitView": hit.map { String(describing: type(of: $0)) } ?? "nil",
                "isTabButton": hit === button,
                "reachesTabButton": hit.map { chainReaches(button, from: $0) } ?? false,
                "withoutOverride": raw.map { String(describing: type(of: $0)) } ?? "nil",
                "chain": hit.map(responderChainDescription) ?? []
            ])
        }
        // The close button is the one press the drag work must not break, and
        // it's normally hidden until hover -- reveal it just long enough to
        // ask what a press over it resolves to.
        // The pill positions its own subviews in its `layout()`, which runs
        // after the strip has assigned this button's frame -- so force that
        // through first, or the close button is still at .zero and the probe
        // measures nothing.
        button.layoutSubtreeIfNeeded()
        let closeProbe: [String: Any] = button.withCloseButtonVisible {
            let inButton = button.closeButtonProbePoint
            let inContent = button.convert(inButton, to: contentView)
            return [
                "probePoint": describe(NSRect(origin: inButton, size: .zero)),
                "closeButtonFrame": describe(button.closeButtonProbeFrame),
                "hitView": button.describeHit(contentView.hitTest(inContent)),
                "withoutOverride": button.describeHit(
                    button.hitTestIgnoringOverride(button.convert(inButton, to: button.superview))
                )
            ]
        }
        record("hitTestProbe", [
            "tabIndex": button.index,
            "buttonFrame": describe(button.frame),
            "probes": probes,
            "closeButton": closeProbe
        ])
    }

    private static func chainReaches(_ target: NSView, from view: NSView) -> Bool {
        var current: NSView? = view
        while let candidate = current {
            if candidate === target { return true }
            current = candidate.superview
        }
        return false
    }

    private static func responderChainDescription(from view: NSView) -> [String] {
        var chain: [String] = []
        var current: NSView? = view
        while let candidate = current, chain.count < 8 {
            chain.append(String(describing: type(of: candidate)))
            current = candidate.superview
        }
        return chain
    }

    static func describe(_ rect: NSRect) -> String {
        String(format: "x=%.1f y=%.1f w=%.1f h=%.1f", rect.origin.x, rect.origin.y, rect.width, rect.height)
    }
}
