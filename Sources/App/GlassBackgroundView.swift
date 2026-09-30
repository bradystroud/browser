import AppKit

/// The two native button treatments used by the browser chrome.
///
/// Standalone controls use AppKit's real glass bezel on macOS 26+, which
/// supplies the same material, pointer response and pressed animation as a
/// system toolbar button. Controls embedded inside an existing glass surface
/// stay visually quiet until hover so they do not become a bubble inside a
/// bubble. Older macOS versions fall back to the native toolbar bezel.
enum ChromeButtonAppearance {
    case glass
    case inline
}

extension NSButton {
    func applyChromeAppearance(_ appearance: ChromeButtonAppearance) {
        isBordered = true
        imageScaling = .scaleProportionallyDown
        // A rounded rectangle, never a capsule: the glass bezel's own
        // rounded-rectangle radius is what ChromeMetrics.controlCornerRadius
        // matches (see its doc comment).
        if #available(macOS 26.0, *) {
            borderShape = .roundedRectangle
        }
        contentTintColor = .secondaryLabelColor

        switch appearance {
        case .glass:
            showsBorderOnlyWhileMouseInside = false
            if #available(macOS 26.0, *) {
                bezelStyle = .glass
            } else {
                bezelStyle = .toolbar
            }
        case .inline:
            bezelStyle = .toolbar
            showsBorderOnlyWhileMouseInside = true
        }
    }
}

/// Chrome background used behind the tab strip/toolbar and the omnibox pill.
/// Three-tier fallback, re-evaluated every time it (re)builds:
///
/// 1. "Reduce Transparency" (System Settings > Accessibility > Display) --
///    wins regardless of OS version: a plain solid-colored `NSView`.
/// 2. macOS 26+ ("Tahoe") -- the real Liquid Glass material,
///    `NSGlassEffectView` (`AppKit.framework/Headers/NSGlassEffectView.h`,
///    `API_AVAILABLE(macos(26.0))`). This is the actual system material real
///    Safari uses on this OS, not an approximation of it.
/// 3. Older systems (this project's deployment target is 12.0, per CEF's own
///    build config -- see `docs/ai-tasks/browser-qpy-notes.md`) --
///    `NSVisualEffectView` vibrancy, the pre-Tahoe frosted-glass system.
///    Visually close but a genuinely different material; kept only so the
///    app still looks reasonable rather than crashing/no-op'ing pre-26.
///
/// `tintColor` rides `NSGlassEffectView`'s own `tintColor` property on the
/// macOS 26+ path (the real material's tint, not a separate drawn layer) --
/// pre-26 has no such API on `NSVisualEffectView`, so that path falls back
/// to a translucent color layer blended over the vibrancy view instead.
final class GlassBackgroundView: NSView {
    private let legacyMaterial: NSVisualEffectView.Material
    private let legacyBlendingMode: NSVisualEffectView.BlendingMode
    private let solidFallbackColor: NSColor
    /// False for a surface that should never be Liquid Glass, whatever the
    /// OS: the chrome band and the tab sidebar, which the glass controls sit
    /// on. Glass on glass reads as a stack of frosted panes rather than as
    /// controls on a bar, so those surfaces take the plain vibrancy material
    /// (tier 3 below) on every version.
    private let usesGlass: Bool
    private var glassCornerRadius: CGFloat
    private var glassTintColor: NSColor?
    private var shadowEnabled = false

    /// `NSGlassEffectView` on macOS 26+, stored untyped -- a stored property
    /// of that literal type would force this whole class's declaration to be
    /// availability-gated, which isn't possible for something referenced
    /// unconditionally from BrowserWindowController.swift/TabStripView.swift.
    /// Cast back to `NSGlassEffectView` (inside an `#available` check) only
    /// where its own API is actually needed.
    private var modernGlassView: NSView?
    private var legacyEffectView: NSVisualEffectView?
    private var solidView: NSView?
    /// Pre-26/Reduce-Transparency-only tint approximation -- see applyTint().
    private var legacyTintOverlay: NSView?

    /// Real content callers should add subviews to -- **not `self`
    /// directly** (browser-0y1: tab titles/favicons rendered blurred/
    /// smeared, and a selected tab's title disappeared entirely, because
    /// TabButtonView/TabGroupHeaderView were adding their labels as plain
    /// sibling subviews of their own `NSGlassEffectView` instance rather
    /// than inside its `contentView`). `NSGlassEffectView`'s own header doc
    /// comment is explicit: "only guarantees the `contentView` will be
    /// placed inside the glass effect; arbitrary subviews aren't guaranteed
    /// specific behavior with regard to z-order in relation to the content
    /// view or glass effect" -- in practice, on macOS 26+, a sibling
    /// subview can end up composited *underneath* the glass's own blur/
    /// refraction pass instead of on top of it, which is exactly the
    /// symptom reported. `rebuild()` below reparents this same container
    /// into whichever background is currently active (the glass's
    /// `contentView` on 26+, a plain subview of `self` pre-26/solid) --
    /// its own children are never touched, so callers just add to this
    /// once and never think about it again.
    let contentContainer = NSView()

    init(
        material: NSVisualEffectView.Material,
        blendingMode: NSVisualEffectView.BlendingMode,
        solidFallbackColor: NSColor,
        cornerRadius: CGFloat = 0,
        usesGlass: Bool = true
    ) {
        self.legacyMaterial = material
        self.legacyBlendingMode = blendingMode
        self.solidFallbackColor = solidFallbackColor
        self.usesGlass = usesGlass
        self.glassCornerRadius = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
        rebuild()
        NotificationCenter.default.addObserver(
            self, selector: #selector(rebuild),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: NSWorkspace.shared
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Blends the profile accent / active tab's theme color into the glass.
    /// On macOS 26+ this sets `NSGlassEffectView.tintColor` directly (the
    /// real material property) -- pre-26 there's no such API on
    /// `NSVisualEffectView`, so it's approximated with a translucent color
    /// layer instead. `nil` clears any tint, returning to a neutral glass.
    var tintColor: NSColor? {
        get { glassTintColor }
        set {
            glassTintColor = newValue
            applyTint()
        }
    }

    var cornerRadius: CGFloat {
        get { glassCornerRadius }
        set {
            glassCornerRadius = newValue
            applyCornerRadius()
        }
    }

    /// A soft drop shadow under the pre-26 vibrancy material, which has no
    /// edge of its own. Never on Liquid Glass, which draws its own. The
    /// shadow lives on this view's own layer, which is never clipped -- only
    /// the material and content inside it are -- so it actually shows.
    var castsShadow: Bool {
        get { shadowEnabled }
        set {
            shadowEnabled = newValue
            applyShadow()
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        applyShadow()
    }

    @objc private func rebuild() {
        modernGlassView?.removeFromSuperview()
        legacyEffectView?.removeFromSuperview()
        solidView?.removeFromSuperview()
        legacyTintOverlay?.removeFromSuperview()
        contentContainer.removeFromSuperview()
        modernGlassView = nil
        legacyEffectView = nil
        solidView = nil
        legacyTintOverlay = nil

        contentContainer.frame = bounds
        contentContainer.autoresizingMask = [.width, .height]

        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            let view = NSView(frame: bounds)
            view.autoresizingMask = [.width, .height]
            view.wantsLayer = true
            view.layer?.backgroundColor = solidFallbackColor.cgColor
            addSubview(view, positioned: .below, relativeTo: nil)
            solidView = view
            addSubview(contentContainer)
        } else if usesGlass, #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: bounds)
            glass.autoresizingMask = [.width, .height]
            glass.style = .regular
            glass.contentView = contentContainer
            addSubview(glass, positioned: .below, relativeTo: nil)
            modernGlassView = glass
        } else {
            let view = NSVisualEffectView(frame: bounds)
            view.autoresizingMask = [.width, .height]
            view.material = legacyMaterial
            view.blendingMode = legacyBlendingMode
            view.state = .active
            addSubview(view, positioned: .below, relativeTo: nil)
            legacyEffectView = view
            addSubview(contentContainer)
        }
        applyCornerRadius()
        applyTint()
    }

    /// The rounded shape is applied to what is *inside* this view -- the
    /// material and the content container -- and never masks this view's own
    /// layer, which is what lets castsShadow's shadow draw outside it. The
    /// content container is clipped on every path, so something drawn along
    /// its edge (the omnibox's loading bar) follows the rounded corners.
    private func applyCornerRadius() {
        layer?.masksToBounds = false
        let clipped: [NSView?] = [legacyEffectView, solidView, legacyTintOverlay, contentContainer]
        for view in clipped.compactMap({ $0 }) {
            view.wantsLayer = true
            view.layer?.cornerRadius = glassCornerRadius
            view.layer?.cornerCurve = .continuous
            view.layer?.masksToBounds = glassCornerRadius > 0
        }
        if #available(macOS 26.0, *), let glass = modernGlassView as? NSGlassEffectView {
            glass.cornerRadius = glassCornerRadius
        }
        applyShadow()
    }

    private func applyShadow() {
        guard let layer else { return }
        guard shadowEnabled, modernGlassView == nil, solidView == nil else {
            layer.shadowOpacity = 0
            layer.shadowPath = nil
            return
        }
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.15
        layer.shadowRadius = 4
        layer.shadowOffset = NSSize(width: 0, height: -1)
        layer.shadowPath = CGPath(
            roundedRect: bounds, cornerWidth: glassCornerRadius, cornerHeight: glassCornerRadius, transform: nil)
    }

    private func applyTint() {
        if #available(macOS 26.0, *), let glass = modernGlassView as? NSGlassEffectView {
            glass.tintColor = glassTintColor
            return
        }
        guard let tint = glassTintColor else {
            legacyTintOverlay?.removeFromSuperview()
            legacyTintOverlay = nil
            return
        }
        let overlay: NSView
        if let existing = legacyTintOverlay {
            overlay = existing
        } else {
            let view = NSView(frame: bounds)
            view.autoresizingMask = [.width, .height]
            view.wantsLayer = true
            // Under the content, never over it: an overlay above
            // contentContainer would tint the text sitting in it.
            addSubview(view, positioned: .below, relativeTo: contentContainer)
            legacyTintOverlay = view
            overlay = view
        }
        overlay.layer?.backgroundColor = tint.cgColor
    }
}

/// A borderless image button that fills faintly under the pointer and a
/// little more while pressed -- for controls that sit *on* a surface (a tab
/// pill, the back/forward group) and so must not bring a bezel of their own.
/// The fill follows `contentTintColor`, so it stays legible on whatever
/// surface the glyph itself was tinted for.
class HoverFillButton: NSButton {
    enum Shape {
        /// A circle inscribed in the bounds.
        case circle
        /// The bounds themselves -- for a segment whose outer corners are
        /// clipped by the rounded surface it sits in.
        case rectangle
    }

    private static let hoverFillAlpha: CGFloat = 0.1
    private static let pressedFillAlpha: CGFloat = 0.18

    private let shape: Shape
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovered = false {
        didSet { if oldValue != isHovered { needsDisplay = true } }
    }

    init(shape: Shape) {
        self.shape = shape
        super.init(frame: .zero)
        isBordered = false
        title = ""
        imagePosition = .imageOnly
        imageScaling = .scaleNone
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isHidden: Bool {
        didSet { if isHidden { isHovered = false } }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func draw(_ dirtyRect: NSRect) {
        if isEnabled, isHovered || isHighlighted {
            let alpha = isHighlighted ? Self.pressedFillAlpha : Self.hoverFillAlpha
            (contentTintColor ?? .labelColor).withAlphaComponent(alpha).setFill()
            switch shape {
            case .circle: NSBezierPath(ovalIn: bounds).fill()
            case .rectangle: bounds.fill(using: .sourceOver)
            }
        }
        super.draw(dirtyRect)
    }
}

/// A hairline in `separatorColor`, re-resolved on every appearance change
/// (a CGColor copied once would stay light-mode grey in dark mode).
final class HairlineView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.separatorColor.cgColor
    }
}
