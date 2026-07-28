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

    /// WCAG relative luminance -- see contrastRatio(against:).
    private var relativeLuminance: CGFloat {
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
}
