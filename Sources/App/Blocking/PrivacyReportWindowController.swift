import AppKit

/// "Privacy Report" (browser-e7r) -- what the content blocker stopped over
/// the last 30 days, for one profile: the headline counts, a day-by-day
/// trend, and the trackers themselves ranked by how many of the user's sites
/// they turned up on.
///
/// A window of its own rather than a section in the Privacy pane, matching
/// Safari. The Settings window is where you change things; this is something
/// you read, it is worth some room, and it has no settings in it at all
/// except the one destructive button that belongs with the data it clears.
///
/// EVERY NUMBER HERE IS LABELLED FOR WHAT IT ACTUALLY IS. "Trackers" is
/// always a count of distinct tracker domains; the much larger count of
/// cancelled requests is shown separately and called requests. Those are not
/// the same number worn differently, and the difference between them is the
/// whole reason this feature was built carefully -- see
/// TrackerReportRecorder.
///
/// WHAT IS NOT HERE: Safari's "percentage of sites that contacted trackers".
/// The denominator would have to be sites visited, whose only source is
/// history -- which the user can clear at any moment (making the percentage
/// leap for no real reason) and which excludes private windows by design. A
/// percentage whose denominator silently changes is worse than no
/// percentage, so this shows the honest count of sites instead. Please do
/// not "complete" the feature by adding it back.
final class PrivacyReportWindowController: NSObject, NSWindowDelegate {
    static let shared = PrivacyReportWindowController()

    private var window: NSWindow?
    private var profile: Profile?

    private override init() {
        super.init()
    }

    func show(for profile: Profile) {
        self.profile = profile
        let content = PrivacyReportViewController(profile: profile)
        content.onClear = { [weak self] in self?.confirmClear() }

        if let window {
            window.contentViewController = content
            window.makeKeyAndOrderFront(nil)
            return
        }
        let created = NSWindow(contentViewController: content)
        created.title = "Privacy Report"
        created.styleMask = [.titled, .closable, .miniaturizable]
        created.delegate = self
        created.center()
        created.makeKeyAndOrderFront(nil)
        window = created
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }

    /// Clearing is destructive and unrecoverable, so it asks first -- the one
    /// place in this window where that is warranted, since every other
    /// control here only reads.
    private func confirmClear() {
        guard let profile, let window else { return }
        let alert = NSAlert()
        alert.messageText = "Clear the Privacy Report for \u{201C}\(profile.name)\u{201D}?"
        alert.informativeText = "The record of which trackers were blocked, and where, will be deleted. Blocking itself is unaffected and carries on exactly as before."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, let profile = self.profile else { return }
            TrackerReportCoordinator.shared.clearReport(for: profile)
            self.show(for: profile)
        }
    }
}

/// The report's contents. Rebuilt from the store on every presentation
/// rather than kept live: a report is a snapshot of the last 30 days, and
/// nothing the user can do in this window changes it except the clear
/// button, which re-presents.
private final class PrivacyReportViewController: NSViewController {
    private static let contentWidth: CGFloat = 560
    private static let margin: CGFloat = 24

    private let profile: Profile
    private let summary: TrackerReportSummary

    var onClear: (() -> Void)?

    init(profile: Profile) {
        self.profile = profile
        summary = (try? TrackerReportCoordinator.shared.store(for: profile)?.summary())
            ?? TrackerReportSummary(trackerCount: 0, siteCount: 0, requestCount: 0, topTrackers: [], days: [])
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let container = NSVisualEffectView()
        container.material = .windowBackground
        container.blendingMode = .behindWindow
        container.state = .followsWindowActiveState

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(headerView())
        stack.addArrangedSubview(statsRow())

        if summary.isEmpty {
            stack.addArrangedSubview(emptyStateView())
        } else {
            stack.addArrangedSubview(sectionLabel("Blocked Per Day"))
            stack.addArrangedSubview(TrackerReportChartView(days: summary.days, width: Self.contentWidth - Self.margin * 2))
            stack.addArrangedSubview(sectionLabel("Most Contacted Trackers"))
            stack.addArrangedSubview(trackerList())
        }

        stack.addArrangedSubview(footerView())

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.margin),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.margin),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.margin),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Self.margin),
        ])
        view = container
    }

    // MARK: - Pieces

    private func headerView() -> NSView {
        let title = NSTextField(labelWithString: "Privacy Report")
        title.font = .systemFont(ofSize: 22, weight: .semibold)

        let dot = ProfileDotView(colorHex: profile.colorHex)
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10),
        ])

        let subtitle = NSTextField(labelWithString: "\(profile.name) · last \(TrackerReportStore.retentionDays) days")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor

        let subtitleRow = NSStackView(views: [dot, subtitle])
        subtitleRow.orientation = .horizontal
        subtitleRow.spacing = 5
        subtitleRow.alignment = .centerY

        let stack = NSStackView(views: [title, subtitleRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        return stack
    }

    /// The three numbers, each with the noun it is actually counting. The
    /// order is deliberate: trackers first because it is the one a person
    /// means, requests last because it is the biggest and the least
    /// meaningful on its own.
    private func statsRow() -> NSView {
        let stack = NSStackView(views: [
            statTile(value: summary.trackerCount, singular: "Tracker", plural: "Trackers", tinted: true),
            statTile(value: summary.siteCount, singular: "Site Affected", plural: "Sites Affected", tinted: false),
            statTile(value: summary.requestCount, singular: "Request Blocked", plural: "Requests Blocked", tinted: false),
        ])
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: Self.contentWidth - Self.margin * 2).isActive = true
        return stack
    }

    private func statTile(value: Int, singular: String, plural: String, tinted: Bool) -> NSView {
        let tile = NSView()
        tile.wantsLayer = true
        tile.layer?.cornerRadius = 10
        tile.layer?.backgroundColor = (tinted
            ? NSColor.controlAccentColor.withAlphaComponent(0.14)
            : NSColor.quaternaryLabelColor.withAlphaComponent(0.35)).cgColor

        let number = NSTextField(labelWithString: Self.decimal(value))
        number.font = .systemFont(ofSize: 26, weight: .medium)
        number.textColor = tinted ? .controlAccentColor : .labelColor

        let caption = NSTextField(labelWithString: value == 1 ? singular : plural)
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [number, caption])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false

        tile.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: tile.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: tile.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: tile.trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: tile.bottomAnchor, constant: -12),
        ])
        return tile
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        return label
    }

    private func trackerList() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: Self.contentWidth - Self.margin * 2).isActive = true

        let widest = summary.topTrackers.first?.siteCount ?? 1
        for entry in summary.topTrackers {
            stack.addArrangedSubview(trackerRow(entry, widestSiteCount: max(widest, 1)))
        }
        return stack
    }

    /// One tracker: its domain, a bar showing how much of the user's
    /// browsing it reached relative to the worst offender, and the two
    /// numbers behind it. The bar is scaled by SITES, not requests -- a
    /// tracker on twelve of your sites is the thing worth seeing at a
    /// glance, and scaling by requests would let one noisy page dominate the
    /// whole chart.
    private func trackerRow(_ entry: TrackerReportEntry, widestSiteCount: Int) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: entry.trackerDomain)
        name.font = .systemFont(ofSize: 12)
        name.lineBreakMode = .byTruncatingMiddle
        name.translatesAutoresizingMaskIntoConstraints = false

        let detail = NSTextField(labelWithString:
            "\(entry.siteCount) site\(entry.siteCount == 1 ? "" : "s") · \(Self.decimal(entry.requestCount)) request\(entry.requestCount == 1 ? "" : "s")")
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .right
        detail.translatesAutoresizingMaskIntoConstraints = false

        let track = NSView()
        track.wantsLayer = true
        track.layer?.cornerRadius = 3
        track.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.3).cgColor
        track.translatesAutoresizingMaskIntoConstraints = false

        let fill = NSView()
        fill.wantsLayer = true
        fill.layer?.cornerRadius = 3
        fill.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        fill.translatesAutoresizingMaskIntoConstraints = false

        row.addSubview(name)
        row.addSubview(detail)
        row.addSubview(track)
        track.addSubview(fill)

        let fraction = CGFloat(entry.siteCount) / CGFloat(widestSiteCount)
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            name.topAnchor.constraint(equalTo: row.topAnchor),
            detail.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            detail.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
            detail.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 10),

            track.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            track.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            track.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 5),
            track.heightAnchor.constraint(equalToConstant: 6),
            track.bottomAnchor.constraint(equalTo: row.bottomAnchor),

            fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            fill.topAnchor.constraint(equalTo: track.topAnchor),
            fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
            // Never a zero-width sliver: a tracker in the list was seen at
            // least once, and a bar that renders as nothing reads as "none".
            fill.widthAnchor.constraint(equalTo: track.widthAnchor, multiplier: max(fraction, 0.04)),
        ])
        return row
    }

    private func emptyStateView() -> NSView {
        let title = NSTextField(labelWithString: "Nothing blocked yet")
        title.font = .systemFont(ofSize: 13, weight: .medium)

        let body = NSTextField(wrappingLabelWithString:
            "Trackers this profile blocks will be listed here. Private windows are never included, by design.")
        body.font = .systemFont(ofSize: 11)
        body.textColor = .secondaryLabelColor
        body.translatesAutoresizingMaskIntoConstraints = false
        body.widthAnchor.constraint(equalToConstant: Self.contentWidth - Self.margin * 2).isActive = true

        let stack = NSStackView(views: [title, body])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        return stack
    }

    private func footerView() -> NSView {
        let note = NSTextField(wrappingLabelWithString:
            "Counted per site and per day. Private windows are never recorded.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .tertiaryLabelColor
        note.translatesAutoresizingMaskIntoConstraints = false

        let clear = NSButton(title: "Clear Report", target: self, action: #selector(clearTapped))
        clear.bezelStyle = .rounded
        clear.isEnabled = !summary.isEmpty
        clear.translatesAutoresizingMaskIntoConstraints = false
        clear.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(note)
        row.addSubview(clear)
        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(equalToConstant: Self.contentWidth - Self.margin * 2),
            note.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            note.centerYAnchor.constraint(equalTo: clear.centerYAnchor),
            note.trailingAnchor.constraint(lessThanOrEqualTo: clear.leadingAnchor, constant: -12),
            clear.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            clear.topAnchor.constraint(equalTo: row.topAnchor),
            clear.bottomAnchor.constraint(equalTo: row.bottomAnchor),
        ])
        return row
    }

    @objc private func clearTapped() {
        onClear?()
    }

    /// "1,247" -- grouped, because the request count is routinely four
    /// digits and an ungrouped one is hard to read at a glance.
    private static func decimal(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

/// A bar per day across the retention window, scaled to the busiest day.
///
/// Drawn rather than assembled from views: it is thirty rectangles with no
/// interaction, and a custom NSView is both less code and less layout work
/// than thirty constrained subviews. Days with nothing blocked are drawn as
/// an empty slot rather than skipped, so the gaps are visible as gaps and
/// the axis stays a real timeline.
private final class TrackerReportChartView: NSView {
    private let counts: [Int]

    init(days: [TrackerReportDay], width: CGFloat) {
        // Re-expanded into a dense day-by-day series: the store only returns
        // days that had something, and drawing those consecutively would
        // silently compress a quiet fortnight into nothing.
        var byDay: [Int: Int] = [:]
        for day in days {
            byDay[day.day] = day.requestCount
        }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        counts = (0..<TrackerReportStore.retentionDays).reversed().map { offset in
            let date = calendar.date(byAdding: .day, value: -offset, to: today) ?? today
            return byDay[Int(date.timeIntervalSince1970)] ?? 0
        }
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 64))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: width).isActive = true
        heightAnchor.constraint(equalToConstant: 64).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ dirtyRect: NSRect) {
        let maximum = CGFloat(counts.max() ?? 0)
        guard maximum > 0 else { return }

        let slot = bounds.width / CGFloat(counts.count)
        let barWidth = max(slot - 3, 2)
        for (index, count) in counts.enumerated() {
            let fraction = CGFloat(count) / maximum
            // A day with nothing blocked draws only the baseline stub, so an
            // empty day and a barely-busy day cannot be confused.
            let height = count == 0 ? 2 : max(bounds.height * fraction, 3)
            let rect = NSRect(
                x: slot * CGFloat(index) + (slot - barWidth) / 2,
                y: 0,
                width: barWidth,
                height: height
            )
            let color = count == 0
                ? NSColor.quaternaryLabelColor.withAlphaComponent(0.4)
                : NSColor.controlAccentColor.withAlphaComponent(0.85)
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}
