import AppKit

extension NSColor {
    /// Accepts "#RGB" (shorthand) or "#RRGGBB" (full), with or without the
    /// leading "#". The 3-digit form expands each hex digit (so "#0af"
    /// becomes "#00aaff", per the CSS shorthand-hex-color spec) -- real
    /// `<meta name="theme-color">` values in the wild use both forms (see
    /// Tab.swift's theme-color extraction, browser-rhi.5); every other
    /// caller of this initializer already only ever passes 6-digit values,
    /// so this is purely additive.
    convenience init?(hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        let expanded: String
        switch s.count {
        case 3:
            expanded = s.map { "\($0)\($0)" }.joined()
        case 6:
            expanded = s
        default:
            return nil
        }
        guard let value = UInt32(expanded, radix: 16) else { return nil }
        let r = CGFloat((value >> 16) & 0xFF) / 255.0
        let g = CGFloat((value >> 8) & 0xFF) / 255.0
        let b = CGFloat(value & 0xFF) / 255.0
        self.init(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }

    /// "#RRGGBB" for an already-resolved color -- the inverse of init(hex:),
    /// for logging measured colors in a form that can be pasted straight
    /// into a contrast checker (see TabStripView's --tab-contrast-report).
    var hexString: String {
        guard let rgb = usingColorSpace(.sRGB) else { return "?" }
        func byte(_ c: CGFloat) -> Int { Int((min(max(c, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent))
    }

    /// WCAG relative luminance, 0 for black and 1 for white -- see
    /// contrastRatio(against:). Readable outside this file because the tab
    /// strip picks between a light and a dark selection treatment from a
    /// measured luminance rather than from an assumption about which way
    /// the tint went (browser-qpy.1).
    var relativeLuminance: CGFloat {
        guard let rgb = usingColorSpace(.sRGB) else { return 0 }
        func channel(_ c: CGFloat) -> CGFloat {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(rgb.redComponent) + 0.7152 * channel(rgb.greenComponent) + 0.0722 * channel(rgb.blueComponent)
    }

    /// WCAG contrast ratio (1...21), order-independent (lighter/darker of
    /// the pair is resolved internally, so a.contrastRatio(against: b) ==
    /// b.contrastRatio(against: a)).
    func contrastRatio(against other: NSColor) -> CGFloat {
        let lighter = max(relativeLuminance, other.relativeLuminance)
        let darker = min(relativeLuminance, other.relativeLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// Shared tuning for browser-rhi.5's site-theme-color tint: how much of
    /// the theme color to blend into a background, and the minimum contrast
    /// the *result* must still clear against `.labelColor` before it's used
    /// -- below that, tinted(withThemeColorHex:) returns nil (skip the tint
    /// entirely) rather than risk washing out label text. Not a full WCAG
    /// text-contrast audit (this is a decorative chrome background, not a
    /// text color) -- a quick sanity guard against the worst extremes, per
    /// the task's own "keep text/contrast accessible" / "skip tint entirely
    /// if the color fails a quick contrast check" wording.
    static let themeTintBlendFraction: CGFloat = 0.14
    static let themeTintMinimumContrastRatio: CGFloat = 3.0

    /// Blends `hex` into this color at themeTintBlendFraction, returning the
    /// blended result only if it still clears themeTintMinimumContrastRatio
    /// against `.labelColor` -- nil means "don't tint," either because `hex`
    /// didn't parse (see the 3/6-digit init above) or the result would hurt
    /// readability too much.
    func tinted(withThemeColorHex hex: String?) -> NSColor? {
        guard let hex, let themeColor = NSColor(hex: hex),
              let blended = blended(withFraction: Self.themeTintBlendFraction, of: themeColor),
              blended.contrastRatio(against: .labelColor) >= Self.themeTintMinimumContrastRatio
        else { return nil }
        return blended
    }

    /// This color's concrete sRGB components as they render under
    /// `appearance`.
    ///
    /// A dynamic system color (`controlBackgroundColor`, `labelColor`,
    /// `windowBackgroundColor`, …) carries no components of its own until
    /// something resolves it, and asking one for `redComponent` outside a
    /// drawing context yields its *light* variant no matter what the view
    /// is actually drawn in. Every luminance measurement below that skipped
    /// this step would therefore be wrong in dark mode -- and wrong in the
    /// direction that hides a contrast problem rather than reporting it.
    func resolvedSRGB(for appearance: NSAppearance) -> NSColor {
        var resolved = self
        appearance.performAsCurrentDrawingAppearance {
            resolved = self.usingColorSpace(.sRGB) ?? self
        }
        return resolved
    }

    /// This color composited at `alpha` over `background` -- i.e. what the
    /// eye actually receives from a translucent overlay, which is the only
    /// thing a contrast ratio involving one can meaningfully be measured
    /// on. (`contrastRatio(against:)` ignores alpha entirely: relative
    /// luminance is defined for opaque colors.)
    func composited(alpha: CGFloat, over background: NSColor) -> NSColor {
        guard let base = background.usingColorSpace(.sRGB), let top = usingColorSpace(.sRGB),
              let blended = base.blended(withFraction: alpha, of: top) else { return self }
        return blended
    }

    /// This color moved away from `reference` in luminance -- keeping its
    /// hue -- until the pair clears `target`, or as far as sRGB allows if
    /// they can't. Returns `self` unchanged when the pair already clears.
    ///
    /// Direction is chosen from `reference`'s measured luminance rather
    /// than assumed: a light backdrop is escaped by darkening, a dark one
    /// by lightening. That is the whole point -- the old selected-tab
    /// treatment was fixed, so it only separated from the backdrops it
    /// happened to be designed against (browser-qpy.1).
    ///
    /// Channel scaling toward black/white rather than an HSB brightness
    /// change: AppKit has no sRGB HSB initializer (`NSColor(hue:…)` is
    /// calibrated RGB), so going through HSB would shift the hue slightly
    /// on every step of the search.
    func nudged(awayFrom reference: NSColor, target: CGFloat) -> NSColor {
        guard let base = usingColorSpace(.sRGB), let other = reference.usingColorSpace(.sRGB),
              base.contrastRatio(against: other) < target else { return self }
        let darken = other.relativeLuminance > 0.5
        var best = base
        for step in 1...25 {
            let k = CGFloat(step) * 0.04
            func moved(_ c: CGFloat) -> CGFloat { darken ? c * (1 - k) : c + (1 - c) * k }
            let candidate = NSColor(
                srgbRed: moved(base.redComponent), green: moved(base.greenComponent),
                blue: moved(base.blueComponent), alpha: base.alphaComponent
            )
            best = candidate
            if candidate.contrastRatio(against: other) >= target { return candidate }
        }
        return best
    }
}
