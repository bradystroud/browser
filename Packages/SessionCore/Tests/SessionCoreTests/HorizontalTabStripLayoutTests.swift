import Foundation
import Testing
@testable import SessionCore

private typealias Layout = HorizontalTabStripLayout

private func layout(_ items: [Layout.Item], width: CGFloat, leadingInset: CGFloat = 0) -> Layout {
    Layout(items: items, viewportWidth: width, leadingInset: leadingInset, sidePadding: 8, spacing: 6)
}

private func lastMaxX(_ layout: Layout) -> CGFloat {
    (layout.origins.last ?? 0) + (layout.widths.last ?? 0)
}

@Test func fewTabsShareTheWholeStrip() {
    let result = layout([.tab, .tab], width: 1000)
    // (1000 - 8*2 - 6) / 2
    #expect(result.widths == [489, 489])
    #expect(result.origins == [8, 503])
    #expect(lastMaxX(result) == 992)
    #expect(result.contentWidth == 1000)
    #expect(!result.overflows)
}

@Test func tabsStopShrinkingAtTheMinimumWidth() {
    let result = layout(Array(repeating: .tab, count: 50), width: 1000)
    #expect(result.widths.allSatisfy { $0 == Layout.minTabWidth })
}

@Test func anOverflowingRowIsWideEnoughToReachTheLastTab() {
    let result = layout(Array(repeating: .tab, count: 50), width: 1000)
    #expect(result.overflows)
    // 8 + 50*80 + 49*6 + 8
    #expect(result.contentWidth == 4310)
    #expect(lastMaxX(result) + 8 == result.contentWidth)
}

@Test func everyItemFitsInsideTheContentWidthAtAnyViewportWidth() {
    let items: [Layout.Item] = [.pinnedTab, .pinnedTab, .pinnedTab]
        + [.groupHeader(isCollapsed: false)] + Array(repeating: .tab, count: 8)
        + [.groupHeader(isCollapsed: true)]
        + Array(repeating: .tab, count: 30)
    for width in stride(from: CGFloat(300), through: 2400, by: 100) {
        let result = layout(items, width: width, leadingInset: 12)
        #expect(result.origins.first == 20)
        #expect(lastMaxX(result) <= result.contentWidth - 8, "width \(width)")
        #expect(result.contentWidth >= width)
        #expect(result.overflows == (lastMaxX(result) + 8 > width), "width \(width)")
    }
}

@Test func pinnedTabsAndGroupHeadersKeepTheirFixedWidths() {
    let items: [Layout.Item] = [.pinnedTab, .groupHeader(isCollapsed: false), .tab, .groupHeader(isCollapsed: true), .tab]
    let result = layout(items, width: 1200)
    #expect(result.widths[0] == Layout.pinnedTabWidth)
    #expect(result.widths[1] == Layout.groupHeaderWidth)
    #expect(result.widths[3] == Layout.collapsedGroupHeaderWidth)
    #expect(result.widths[2] == result.widths[4])
    #expect(lastMaxX(result) == 1192)
}

@Test func itemsDoNotOverlap() {
    let items: [Layout.Item] = [.pinnedTab, .groupHeader(isCollapsed: false)] + Array(repeating: .tab, count: 25)
    let result = layout(items, width: 700)
    for index in 1..<items.count {
        #expect(result.origins[index] == result.origins[index - 1] + result.widths[index - 1] + 6)
    }
}

@Test func anEmptyStripStillFillsItsViewport() {
    let result = layout([], width: 640)
    #expect(result.origins.isEmpty)
    #expect(result.contentWidth == 640)
    #expect(!result.overflows)
}
