import AppKit

/// The one description of what a list surface looks like in this app.
///
/// Every table and outline view here -- History, Bookmarks, Downloads,
/// Reading List, Safari Import, and the Profiles/Privacy/Passwords/Cards/
/// Addresses/Routing Rules settings panes -- was built the same way, and so
/// carried the same dated defaults: an `NSScrollView` with `.bezelBorder`
/// (the sunken 3D well AppKit has drawn since the 10.x days) wrapped around
/// a table left at `.automatic` style with alternating row stripes and the
/// 17pt default row height. Alternating stripes and the bezel were both
/// dropped from Apple's own apps in Big Sur, and 17pt leaves a 13pt label
/// with barely two points of air above and below it.
///
/// Applying it from here rather than at each of the eleven call sites means
/// the app has one answer to "what does a list look like", and changing that
/// answer stays a one-file edit -- the same reason `RoutingCore` keeps one
/// copy of the matcher.
enum ListAppearance {
    /// Comfortable for a single line of 13pt text, and what `.inset` style
    /// is proportioned for. Call sites whose rows carry more than one line
    /// (Downloads, Safari Import) pass their own.
    static let rowHeight: CGFloat = 24

    /// Rounds the well the list sits in, in place of the bezel.
    static let cornerRadius: CGFloat = 8

    /// `scrollView` must already be the table's enclosing scroll view; this
    /// only restyles, it never reparents or resizes, so it is safe to call
    /// at any point in a pane's own frame-based layout.
    static func apply(to tableView: NSTableView, in scrollView: NSScrollView, rowHeight: CGFloat? = nil) {
        scrollView.borderType = .noBorder
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = cornerRadius
        scrollView.layer?.masksToBounds = true
        scrollView.layer?.borderWidth = 0.5
        scrollView.layer?.borderColor = NSColor.separatorColor.cgColor

        // `.inset` is what gives a row its inset, rounded selection instead
        // of a full-bleed rectangle -- the treatment every first-party list
        // has used since Big Sur, and the reason the stripes below are no
        // longer needed to tell one row from the next.
        tableView.style = .inset
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.gridStyleMask = []
        tableView.rowHeight = rowHeight ?? Self.rowHeight
    }
}
