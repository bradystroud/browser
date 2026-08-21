import AppKit

private final class ContentBlockerPopoverViewController: NSViewController {
    private static let width: CGFloat = 300
    private static let margin: CGFloat = 14
    /// How many trackers are named before the rest are summarised. Enough to
    /// recognise the usual suspects on a news page, few enough that the
    /// popover stays a glance rather than a document.
    private static let namedTrackerLimit = 5

    private let blockedRequestCount: Int
    private let trackerDomains: [String]
    private let host: String
    private let isAllowlisted: Bool
    private let isPrivate: Bool
    private let onToggle: (Bool) -> Void
    private let onShowReport: (() -> Void)?
    private var checkbox: NSButton!

    init(
        blockedRequestCount: Int,
        trackerDomains: [String],
        host: String,
        isAllowlisted: Bool,
        isPrivate: Bool,
        onToggle: @escaping (Bool) -> Void,
        onShowReport: (() -> Void)?
    ) {
        self.blockedRequestCount = blockedRequestCount
        self.trackerDomains = trackerDomains
        self.host = host
        self.isAllowlisted = isAllowlisted
        self.isPrivate = isPrivate
        self.onToggle = onToggle
        self.onShowReport = onShowReport
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// "3 trackers blocked on this page", with the request count as a
    /// secondary line rather than the headline.
    ///
    /// The two numbers are deliberately not the same one worn differently:
    /// `trackerDomains` counts distinct block-list entries, `blockedRequestCount`
    /// counts cancelled requests, and one tracker can easily account for
    /// forty of the latter. Showing the request count as "trackers blocked"
    /// -- which is what this popover used to do -- overstates by whatever
    /// that ratio happens to be. See TrackerReportRecorder.
    private var headlineText: String {
        if trackerDomains.isEmpty {
            return blockedRequestCount == 0
                ? "No trackers blocked on this page"
                : "\(blockedRequestCount) request\(blockedRequestCount == 1 ? "" : "s") blocked on this page"
        }
        let count = trackerDomains.count
        return "\(count) tracker\(count == 1 ? "" : "s") blocked on this page"
    }

    private var detailText: String? {
        guard !trackerDomains.isEmpty else { return nil }
        let named = trackerDomains.prefix(Self.namedTrackerLimit)
        var text = named.joined(separator: ", ")
        let remaining = trackerDomains.count - named.count
        if remaining > 0 {
            text += " and \(remaining) more"
        }
        if blockedRequestCount > trackerDomains.count {
            text += " — \(blockedRequestCount) requests in total"
        }
        return text
    }

    override func loadView() {
        let container = NSView()
        let margin = Self.margin

        let shield = NSImageView()
        shield.image = NSImage(systemSymbolName: "shield.lefthalf.filled", accessibilityDescription: nil)
        shield.contentTintColor = trackerDomains.isEmpty ? .secondaryLabelColor : .controlAccentColor
        shield.translatesAutoresizingMaskIntoConstraints = false

        let headline = NSTextField(wrappingLabelWithString: headlineText)
        headline.font = .systemFont(ofSize: 13, weight: .semibold)
        headline.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        if let detailText {
            let detail = NSTextField(wrappingLabelWithString: detailText)
            detail.font = .systemFont(ofSize: 11)
            detail.textColor = .secondaryLabelColor
            stack.addArrangedSubview(detail)
        }

        let checkboxField = NSButton(
            checkboxWithTitle: "Allow ads & trackers on \(host)",
            target: self, action: #selector(toggled)
        )
        checkboxField.state = isAllowlisted ? .on : .off
        checkboxField.isEnabled = !isPrivate
        stack.addArrangedSubview(checkboxField)
        checkbox = checkboxField

        if isPrivate {
            let note = NSTextField(wrappingLabelWithString: "Site settings aren't saved in Private Browsing, and nothing is added to the Privacy Report.")
            note.font = .systemFont(ofSize: 11)
            note.textColor = .secondaryLabelColor
            stack.addArrangedSubview(note)
        } else if let onShowReport {
            let button = NSButton(title: "Privacy Report…", target: self, action: #selector(showReport))
            button.bezelStyle = .rounded
            button.controlSize = .small
            stack.addArrangedSubview(button)
        }

        container.addSubview(shield)
        container.addSubview(headline)
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: Self.width),

            shield.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),
            shield.topAnchor.constraint(equalTo: container.topAnchor, constant: margin),
            shield.widthAnchor.constraint(equalToConstant: 18),
            shield.heightAnchor.constraint(equalToConstant: 18),

            headline.leadingAnchor.constraint(equalTo: shield.trailingAnchor, constant: 8),
            headline.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -margin),
            headline.firstBaselineAnchor.constraint(equalTo: shield.bottomAnchor, constant: -3),

            stack.leadingAnchor.constraint(equalTo: headline.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -margin),
            stack.topAnchor.constraint(equalTo: headline.bottomAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -margin),
        ])

        view = container
        // Resolved before it is read: fittingSize on a view whose constraints
        // have not been solved yet reports the unconstrained size, which for
        // a wrapping label is a single very long line. The popover would then
        // open too short and clip its own text.
        container.layoutSubtreeIfNeeded()
        preferredContentSize = container.fittingSize
    }

    @objc private func toggled() {
        onToggle(checkbox.state == .on)
    }

    @objc private func showReport() {
        onShowReport?()
    }
}

/// Content blocker toolbar popover (browser-12m.5.1.1): shown when the user
/// clicks the toolbar's shield/count button. Names the trackers blocked on
/// the page in front of the user (browser-e7r), plus a one-click "allow ads
/// & trackers on this site" toggle, writing the exact same per-profile
/// BlockingSettings.allowlistedHosts the Privacy pane's own "Add Allowed
/// Site…" flow does -- ContentBlockerCoordinator is the one place both this
/// and the Privacy pane persist through, so they can never drift out of sync
/// with each other.
///
/// The names come from the tab's own per-page-load set, not from the privacy
/// report's database: this popover is about the page currently on screen, so
/// it must not show a tracker that was blocked here yesterday and not today.
/// The 30-day view is the Privacy Report window, which this links to.
///
/// Private windows: the checkbox is shown but disabled. A private window's
/// "private" pseudo-profile (see ContentBlockerCoordinator.pushSnapshot's
/// own doc comment) is shared across every private window, this session and
/// every future one -- writing an allowlist entry for it would leak one
/// private window's "allow this site" choice into every other private
/// window, present or future, which is exactly the persistence Private
/// Browsing exists to avoid. Reading the (always-default, since nothing
/// ever writes it) settings for display is harmless; this controller just
/// never calls updateSettings for a private window at all. The blocked
/// trackers themselves are still named -- that is this window's own live
/// state, not a record of it, and it disappears with the window.
final class ContentBlockerToolbarController: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()

    override init() {
        super.init()
        popover.behavior = .transient
        popover.delegate = self
    }

    var isShowing: Bool { popover.isShown }

    /// `trackerDomains` defaults to empty only so this stays callable from a
    /// call site that has not been updated to pass it yet; with none, the
    /// popover falls back to reporting requests rather than inventing a
    /// tracker count it does not have.
    func toggle(
        anchorView: NSView,
        profileId: String,
        host: String,
        blockedCount: Int,
        trackerDomains: Set<String> = [],
        isPrivate: Bool
    ) {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        let settings = ContentBlockerCoordinator.shared.settings(forProfileId: profileId)
        let content = ContentBlockerPopoverViewController(
            blockedRequestCount: blockedCount,
            trackerDomains: trackerDomains.sorted(),
            host: host,
            isAllowlisted: settings.allowlistedHosts.contains(host),
            isPrivate: isPrivate,
            onToggle: { allow in
                guard !isPrivate else { return }
                var updated = settings
                if allow {
                    if !updated.allowlistedHosts.contains(host) {
                        updated.allowlistedHosts.append(host)
                    }
                } else {
                    updated.allowlistedHosts.removeAll { $0 == host }
                }
                ContentBlockerCoordinator.shared.updateSettings(updated, forProfileId: profileId)
            },
            onShowReport: isPrivate ? nil : { [weak self] in
                self?.dismiss()
                guard let profile = ProfileManager.shared.profile(id: profileId) else { return }
                PrivacyReportWindowController.shared.show(for: profile)
            }
        )
        popover.contentViewController = content
        popover.contentSize = content.preferredContentSize
        popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)
    }

    func dismiss() {
        if popover.isShown {
            popover.performClose(nil)
        }
    }
}
