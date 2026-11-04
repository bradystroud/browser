import Foundation

/// Widths and positions of the horizontal tab strip's items, and how wide the
/// row of them is in total.
///
/// Pinned tabs and group headers have fixed widths; every other tab shares
/// what is left of the viewport evenly, down to `minTabWidth`. Below that the
/// tabs stop shrinking and the row grows wider than the viewport, which the
/// strip then scrolls -- `contentWidth` is how wide its document has to be for
/// the last item to be reachable.
public struct HorizontalTabStripLayout: Equatable {
    public enum Item: Equatable {
        case pinnedTab
        case tab
        case groupHeader(isCollapsed: Bool)
    }

    /// A tab's title is inset by the favicon's width on both sides (see
    /// TabButtonView.layout), so at 80pt only an ellipsis fits; this leaves
    /// room for the first word or two.
    public static let minTabWidth: CGFloat = 120
    /// Just enough for a centered favicon, with no title or close button.
    public static let pinnedTabWidth: CGFloat = 36
    /// Expanded shows the group's name; collapsed only a color dot and count.
    public static let groupHeaderWidth: CGFloat = 110
    public static let collapsedGroupHeaderWidth: CGFloat = 50

    /// Leading x of each item, in the same order as the items passed in.
    public let origins: [CGFloat]
    public let widths: [CGFloat]
    /// Everything from x = 0 to the trailing padding after the last item.
    /// Never less than the viewport, so a short row still fills it.
    public let contentWidth: CGFloat
    public let viewportWidth: CGFloat

    public var overflows: Bool { contentWidth > viewportWidth }

    public init(
        items: [Item],
        viewportWidth: CGFloat,
        leadingInset: CGFloat,
        sidePadding: CGFloat,
        spacing: CGFloat
    ) {
        let available = max(0, viewportWidth - leadingInset - sidePadding * 2)
        let totalSpacing = items.count > 1 ? spacing * CGFloat(items.count - 1) : 0

        var fixedWidthTotal: CGFloat = 0
        var flexibleCount = 0
        for item in items {
            if let fixed = Self.fixedWidth(of: item) {
                fixedWidthTotal += fixed
            } else {
                flexibleCount += 1
            }
        }
        let remaining = max(0, available - totalSpacing - fixedWidthTotal)
        let even = flexibleCount > 0 ? remaining / CGFloat(flexibleCount) : 0
        // No upper bound, so two tabs take half the strip each, as in Safari.
        let flexibleWidth = max(Self.minTabWidth, even)

        var origins: [CGFloat] = []
        var widths: [CGFloat] = []
        origins.reserveCapacity(items.count)
        widths.reserveCapacity(items.count)
        var x = leadingInset + sidePadding
        for item in items {
            let width = Self.fixedWidth(of: item) ?? flexibleWidth
            origins.append(x)
            widths.append(width)
            x += width + spacing
        }
        let rowEnd = items.isEmpty ? x : x - spacing
        self.origins = origins
        self.widths = widths
        self.viewportWidth = viewportWidth
        self.contentWidth = max(viewportWidth, rowEnd + sidePadding)
    }

    private static func fixedWidth(of item: Item) -> CGFloat? {
        switch item {
        case .pinnedTab: return pinnedTabWidth
        case .tab: return nil
        case .groupHeader(let isCollapsed): return isCollapsed ? collapsedGroupHeaderWidth : groupHeaderWidth
        }
    }
}
