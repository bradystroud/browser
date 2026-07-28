import AppKit

/// A background view that renders as translucent `NSVisualEffectView`
/// vibrancy normally, or a plain solid-colored `NSView` when the user has
/// "Reduce Transparency" on (System Settings > Accessibility > Display) --
/// per browser-qpy's explicit requirement to respect that setting rather
/// than force translucency on everyone. Swaps live if the setting changes
/// while the app is running (`NSWorkspace` posts a notification for this),
/// not just at creation time.
///
/// Used for every glass surface in the liquid-glass restyle (browser-qpy):
/// the unified tab-strip/toolbar chrome background and the omnibox pill's
/// own background, each with their own material/blending choice but the
/// same reduce-transparency behavior.
final class GlassBackgroundView: NSView {
    private let material: NSVisualEffectView.Material
    private let blendingMode: NSVisualEffectView.BlendingMode
    private let solidFallbackColor: NSColor
    private var effectView: NSVisualEffectView?
    private var solidView: NSView?

    init(
        material: NSVisualEffectView.Material,
        blendingMode: NSVisualEffectView.BlendingMode,
        solidFallbackColor: NSColor,
        cornerRadius: CGFloat = 0
    ) {
        self.material = material
        self.blendingMode = blendingMode
        self.solidFallbackColor = solidFallbackColor
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = true
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

    @objc private func rebuild() {
        effectView?.removeFromSuperview()
        solidView?.removeFromSuperview()
        effectView = nil
        solidView = nil

        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            let view = NSView(frame: bounds)
            view.autoresizingMask = [.width, .height]
            view.wantsLayer = true
            view.layer?.backgroundColor = solidFallbackColor.cgColor
            addSubview(view, positioned: .below, relativeTo: nil)
            solidView = view
        } else {
            let view = NSVisualEffectView(frame: bounds)
            view.autoresizingMask = [.width, .height]
            view.material = material
            view.blendingMode = blendingMode
            view.state = .active
            addSubview(view, positioned: .below, relativeTo: nil)
            effectView = view
        }
    }
}
