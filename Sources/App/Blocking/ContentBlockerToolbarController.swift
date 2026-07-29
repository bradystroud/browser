import AppKit

private final class ContentBlockerPopoverViewController: NSViewController {
    private static let contentSize = NSSize(width: 280, height: 108)

    private let blockedCount: Int
    private let host: String
    private let isAllowlisted: Bool
    private let isPrivate: Bool
    private let onToggle: (Bool) -> Void
    private var checkbox: NSButton!

    init(blockedCount: Int, host: String, isAllowlisted: Bool, isPrivate: Bool, onToggle: @escaping (Bool) -> Void) {
        self.blockedCount = blockedCount
        self.host = host
        self.isAllowlisted = isAllowlisted
        self.isPrivate = isPrivate
        self.onToggle = onToggle
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = Self.contentSize
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let size = Self.contentSize
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        let margin: CGFloat = 14

        let countText = blockedCount == 0
            ? "No trackers blocked on this page"
            : "\(blockedCount) tracker\(blockedCount == 1 ? "" : "s") blocked on this page"
        let countLabel = NSTextField(labelWithString: countText)
        countLabel.font = .boldSystemFont(ofSize: 13)
        countLabel.frame = NSRect(x: margin, y: size.height - margin - 18, width: size.width - margin * 2, height: 18)
        container.addSubview(countLabel)

        let checkboxField = NSButton(
            checkboxWithTitle: "Allow ads & trackers on \(host)",
            target: self, action: #selector(toggled)
        )
        checkboxField.state = isAllowlisted ? .on : .off
        checkboxField.isEnabled = !isPrivate
        checkboxField.frame = NSRect(
            x: margin, y: size.height - margin - 18 - 8 - 20,
            width: size.width - margin * 2, height: 20
        )
        container.addSubview(checkboxField)
        checkbox = checkboxField

        if isPrivate {
            let note = NSTextField(wrappingLabelWithString: "Site settings aren't saved in Private Browsing.")
            note.font = .systemFont(ofSize: 11)
            note.textColor = .secondaryLabelColor
            note.frame = NSRect(x: margin, y: margin, width: size.width - margin * 2, height: 30)
            container.addSubview(note)
        }

        view = container
    }

    @objc private func toggled() {
        onToggle(checkbox.state == .on)
    }
}

/// Content blocker toolbar popover (browser-12m.5.1.1): shown when the user
/// clicks the toolbar's shield/count button. A read-only blocked-count
/// display plus a one-click "allow ads & trackers on this site" toggle,
/// writing the exact same per-profile BlockingSettings.allowlistedHosts the
/// Privacy pane's own "Add Allowed Site…" flow does -- ContentBlockerCoordinator
/// is the one place both this and the Privacy pane persist through, so
/// they can never drift out of sync with each other.
///
/// Private windows: the checkbox is shown but disabled. A private window's
/// "private" pseudo-profile (see ContentBlockerCoordinator.pushSnapshot's
/// own doc comment) is shared across every private window, this session and
/// every future one -- writing an allowlist entry for it would leak one
/// private window's "allow this site" choice into every other private
/// window, present or future, which is exactly the persistence Private
/// Browsing exists to avoid. Reading the (always-default, since nothing
/// ever writes it) settings for display is harmless; this controller just
/// never calls updateSettings for a private window at all.
final class ContentBlockerToolbarController: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()

    override init() {
        super.init()
        popover.behavior = .transient
        popover.delegate = self
    }

    var isShowing: Bool { popover.isShown }

    func toggle(anchorView: NSView, profileId: String, host: String, blockedCount: Int, isPrivate: Bool) {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        let settings = ContentBlockerCoordinator.shared.settings(forProfileId: profileId)
        let content = ContentBlockerPopoverViewController(
            blockedCount: blockedCount,
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
