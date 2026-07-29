import AppKit

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
    private var glassCornerRadius: CGFloat
    private var glassTintColor: NSColor?

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
        cornerRadius: CGFloat = 0
    ) {
        self.legacyMaterial = material
        self.legacyBlendingMode = blendingMode
        self.solidFallbackColor = solidFallbackColor
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
        } else if #available(macOS 26.0, *) {
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

    private func applyCornerRadius() {
        // Always kept in sync on this container's own layer too (not just
        // the internal material view) -- callers set a border/shadow
        // directly on `self.layer` (see BrowserWindowController's
        // omniboxContainerView setup), and a CALayer border/mask always
        // follows its own layer's cornerRadius, not a separate subview's.
        // Redundant with the real glass view masking its own corners on
        // macOS 26+, but harmless (same shape, same rect).
        layer?.cornerRadius = glassCornerRadius
        layer?.masksToBounds = glassCornerRadius > 0
        if #available(macOS 26.0, *), let glass = modernGlassView as? NSGlassEffectView {
            glass.cornerRadius = glassCornerRadius
        }
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
            addSubview(view)
            legacyTintOverlay = view
            overlay = view
        }
        overlay.layer?.backgroundColor = tint.cgColor
    }
}
