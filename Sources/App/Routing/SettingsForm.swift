import AppKit

/// The layout every form-style Settings pane shares: a two-column
/// NSGridView with right-aligned labels on the left and controls on the
/// right, the arrangement macOS's own settings windows use. Sections are
/// set apart by a separator line with `sectionSpacing` around it; rows
/// within a section are `rowSpacing` apart; and help text sits under the
/// control it explains as an 11pt secondary footnote.
///
/// The control column has a fixed width, so a wrapping footnote always
/// wraps at the same place, and the pane's height (`fittingHeight`) depends
/// only on what the rows currently say and which of them are hidden --
/// never on the window's width. The grid is centered in the pane.
final class SettingsForm {
    static let rowSpacing: CGFloat = 8
    static let sectionSpacing: CGFloat = 20
    static let columnSpacing: CGFloat = 8
    static let controlColumnWidth: CGFloat = 400
    static let margin: CGFloat = 20
    /// Footnotes hug the control above them rather than sitting a full row
    /// away, so it's clear which control they belong to.
    static let footnoteGap: CGFloat = 3
    /// A checkbox's title starts this far in from its box, so a footnote
    /// under a checkbox lines up with the title rather than the box.
    static let checkboxTitleIndent: CGFloat = 20

    let grid: NSGridView = {
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = SettingsForm.rowSpacing
        grid.columnSpacing = SettingsForm.columnSpacing
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        grid.column(at: 1).width = SettingsForm.controlColumnWidth
        return grid
    }()

    private var pendingSection = false

    /// Starts a new group: the next row added is preceded by a separator
    /// line with `sectionSpacing` above and below it. Does nothing before
    /// the first row, so a pane never opens with a stray line.
    func beginSection() {
        pendingSection = grid.numberOfRows > 0
    }

    /// One row: `label` (a trailing colon is the caller's to include) in the
    /// left column, and the controls side by side in the right. Several
    /// controls share one row in a horizontal stack, centered vertically,
    /// since a stack has no single baseline to align the label to.
    @discardableResult
    func addRow(_ label: String?, _ controls: NSView...) -> NSGridRow {
        addRow(label.map(Self.label), controls)
    }

    @discardableResult
    func addRow(_ label: NSTextField?, _ controls: [NSView]) -> NSGridRow {
        insertSectionBreakIfNeeded()
        let content: NSView
        if controls.count == 1 {
            content = controls[0]
        } else {
            let stack = NSStackView(views: controls)
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = 8
            content = stack
        }
        let row = grid.addRow(with: [label ?? NSGridCell.emptyContentView, content])
        if controls.count > 1 {
            row.rowAlignment = .none
            row.yPlacement = .center
        }
        return row
    }

    /// A control that should span the control column's full width (a text
    /// field, a slider).
    @discardableResult
    func addFillingRow(_ label: String?, _ control: NSView) -> NSGridRow {
        let row = addRow(label, control)
        row.cell(at: 1).xPlacement = .fill
        return row
    }

    /// A secondary footnote under the row above it. `indented` lines it up
    /// with a checkbox's title instead of the checkbox itself.
    @discardableResult
    func addFootnote(_ footnote: NSTextField, indented: Bool = false) -> NSGridRow {
        let width = Self.controlColumnWidth - (indented ? Self.checkboxTitleIndent : 0)
        footnote.preferredMaxLayoutWidth = width
        let content: NSView
        if indented {
            let container = NSView()
            footnote.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(footnote)
            NSLayoutConstraint.activate([
                footnote.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.checkboxTitleIndent),
                footnote.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                footnote.topAnchor.constraint(equalTo: container.topAnchor),
                footnote.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
            content = container
        } else {
            content = footnote
        }
        let row = grid.addRow(with: [NSGridCell.emptyContentView, content])
        row.topPadding = Self.footnoteGap - Self.rowSpacing
        row.rowAlignment = .none
        row.cell(at: 1).xPlacement = .fill
        return row
    }

    /// Something that belongs to no label and should span both columns --
    /// a table, an explanatory paragraph above a group.
    @discardableResult
    func addSpanningRow(_ view: NSView) -> NSGridRow {
        insertSectionBreakIfNeeded()
        let row = grid.addRow(with: [view, NSGridCell.emptyContentView])
        row.mergeCells(in: NSRange(location: 0, length: 2))
        row.rowAlignment = .none
        row.cell(at: 0).xPlacement = .fill
        return row
    }

    /// Adds the grid to `view`, pinned `margin` from the top and centered
    /// horizontally.
    func install(in view: NSView) {
        view.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: view.topAnchor, constant: Self.margin),
            grid.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])
    }

    /// The height the pane needs to show every visible row, margins
    /// included -- what a form pane returns from preferredContentHeight.
    var fittingHeight: CGFloat {
        (grid.fittingSize.height + Self.margin * 2).rounded(.up)
    }

    private func insertSectionBreakIfNeeded() {
        guard pendingSection else { return }
        pendingSection = false
        let separator = NSBox()
        separator.boxType = .separator
        let row = grid.addRow(with: [separator, NSGridCell.emptyContentView])
        row.mergeCells(in: NSRange(location: 0, length: 2))
        row.rowAlignment = .none
        row.yPlacement = .center
        row.cell(at: 0).xPlacement = .fill
        row.topPadding = Self.sectionSpacing - Self.rowSpacing
        row.bottomPadding = Self.sectionSpacing - Self.rowSpacing
    }

    // MARK: - Standard controls

    /// A left-column label: "Homepage:".
    static func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.alignment = .right
        return label
    }

    /// An 11pt secondary wrapping footnote.
    static func footnote(_ text: String = "") -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.isSelectable = false
        return label
    }

    static func checkbox(_ title: String, target: AnyObject?, action: Selector?) -> NSButton {
        NSButton(checkboxWithTitle: title, target: target, action: action)
    }
}

/// The macOS-standard add/remove control that sits flush under a list:
/// a small-square segmented control with + and − (and optionally more
/// segments after them). Segment 0 adds, segment 1 removes; the owner
/// enables segment 1 only while something removable is selected.
final class SettingsListButtons: NSSegmentedControl {
    static let addSegment = 0
    static let removeSegment = 1

    /// `extraSymbols` become further segments after + and −, each an SF
    /// Symbol name paired with its accessibility description.
    convenience init(target: AnyObject?, action: Selector?, extraSymbols: [(name: String, description: String)] = []) {
        var images: [NSImage] = [
            NSImage(named: NSImage.addTemplateName)!,
            NSImage(named: NSImage.removeTemplateName)!,
        ]
        for symbol in extraSymbols {
            images.append(NSImage(systemSymbolName: symbol.name, accessibilityDescription: symbol.description) ?? NSImage())
        }
        self.init(images: images, trackingMode: .momentary, target: target, action: action)
        segmentStyle = .smallSquare
        setToolTip("Add", forSegment: 0)
        setToolTip("Remove", forSegment: 1)
        for (offset, symbol) in extraSymbols.enumerated() {
            setToolTip(symbol.description, forSegment: offset + 2)
        }
        for segment in 0..<segmentCount {
            setWidth(24, forSegment: segment)
        }
    }

    var canRemove: Bool {
        get { isEnabled(forSegment: Self.removeSegment) }
        set { setEnabled(newValue, forSegment: Self.removeSegment) }
    }
}

/// The layout the table-based Settings panes share (Passwords, and the
/// Autofill pane's Cards, Addresses and Emails): a SettingsForm of options
/// at the top, the list filling the space under it, and a button bar under
/// the list -- the add/remove control attached to the list's bottom-left
/// edge, the pane's other actions right-aligned.
enum SettingsTablePane {
    static let margin: CGFloat = SettingsForm.margin
    /// Between the form above the list and the list itself.
    static let formGap: CGFloat = 12
    /// Tall enough for a handful of rows without the window feeling cramped.
    static let tableHeight: CGFloat = 220
    static let buttonBarHeight: CGFloat = 24

    /// A single − segment, for a list whose rows are only ever added
    /// elsewhere (saved when a page's form is submitted), so there is
    /// nothing for a + to do.
    static func removeOnlyButtons(target: AnyObject?, action: Selector?) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            images: [NSImage(named: NSImage.removeTemplateName)!],
            trackingMode: .momentary,
            target: target,
            action: action
        )
        control.segmentStyle = .smallSquare
        control.setWidth(24, forSegment: 0)
        control.setToolTip("Remove", forSegment: 0)
        return control
    }

    static func preferredHeight(form: SettingsForm?, topMargin: CGFloat) -> CGFloat {
        let formHeight = form.map { $0.grid.fittingSize.height + formGap } ?? 0
        return (topMargin + formHeight + tableHeight + buttonBarHeight + margin).rounded(.up)
    }

    /// Wraps `table` in a scroll view with the app's list styling
    /// (ListAppearance), squared off along its bottom edge so the
    /// add/remove control reads as attached to it.
    static func install(
        in view: NSView,
        topMargin: CGFloat,
        form: SettingsForm?,
        table: NSTableView,
        listButtons: NSSegmentedControl,
        trailingButtons: [NSButton]
    ) {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = table
        ListAppearance.apply(to: table, in: scrollView)
        // Layer coordinates are unflipped: MaxY is the top edge.
        scrollView.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]

        for button in trailingButtons {
            button.bezelStyle = .push
            button.controlSize = .small
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        }
        let buttonStack = NSStackView(views: trailingButtons)
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8

        for subview in [scrollView, listButtons, buttonStack] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }

        let tableTop: NSLayoutConstraint
        if let form {
            view.addSubview(form.grid)
            NSLayoutConstraint.activate([
                form.grid.topAnchor.constraint(equalTo: view.topAnchor, constant: topMargin),
                form.grid.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            ])
            tableTop = scrollView.topAnchor.constraint(equalTo: form.grid.bottomAnchor, constant: formGap)
        } else {
            tableTop = scrollView.topAnchor.constraint(equalTo: view.topAnchor, constant: topMargin)
        }

        // Below the pane's smallest useful height the button bar is pushed
        // past the bottom edge (the hosting SettingsPaneScrollView scrolls)
        // rather than the layout breaking.
        let bottom = listButtons.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -margin)
        bottom.priority = .defaultHigh

        NSLayoutConstraint.activate([
            tableTop,
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -margin),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 60),
            listButtons.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -1),
            listButtons.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            listButtons.heightAnchor.constraint(equalToConstant: buttonBarHeight),
            bottom,
            buttonStack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            buttonStack.centerYAnchor.constraint(equalTo: listButtons.centerYAnchor, constant: 2),
        ])
    }
}
