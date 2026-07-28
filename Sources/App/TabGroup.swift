import Foundation

/// A named, colored, collapsible section of one window's tab strip --
/// Safari-style tab groups, scoped down to fit this app's shell (a single
/// flat tab strip, not Chrome's own tabbed-window UI, which Alloy-style CEF
/// windows don't have anyway). A group is not a separate switchable space:
/// it's a labeled subsection sitting between the pinned prefix and the loose
/// (ungrouped, unpinned) tabs -- see BrowserWindowController's ordering
/// invariant on `tabs`, which this and Tab.groupId together maintain.
///
/// Membership and order are NOT stored here -- they're derived from
/// BrowserWindowController.tabs (every Tab with groupId == this group's id,
/// in their current relative array order), the same "the array order IS the
/// order" approach pinned tabs already use for their own section. This
/// struct is just the group's identity/display/collapse state.
struct TabGroup: Equatable {
    let id: UUID
    var name: String
    var colorHex: String
    /// Collapsed: member tabs are hidden from the strip (but their
    /// engine-side browsers stay alive, same as any other inactive tab) and
    /// skipped by ⌘1-9/Ctrl+Tab cycling -- see
    /// BrowserWindowController.visibleTabIndices.
    var isCollapsed = false

    init(id: UUID = UUID(), name: String, colorHex: String, isCollapsed: Bool = false) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.isCollapsed = isCollapsed
    }
}
