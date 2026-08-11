import Foundation

/// The page-zoom ladder ⌘+/⌘−/⌘0 walk (browser-5kq.15), plus the conversion
/// between a human-facing scale *factor* (1.0 == 100%) and the *logarithmic
/// level* both engines' APIs speak underneath (factor == pow(1.2, level), so
/// level 0 is exactly 100%).
///
/// A fixed ladder rather than a free-floating multiplier for two reasons:
/// repeated presses can't drift onto unrepresentable values like 103%, and
/// clamping at both ends is then a property of the list itself rather than a
/// separate bounds check that could be forgotten at one call site.
enum PageZoom {
    /// Exactly 100%. The value every new tab starts at, and what ⌘0 returns
    /// to -- see `level(forFactor:)` for why this specific constant matters
    /// beyond being an element of `steps`.
    static let defaultFactor: Double = 1.0

    /// Chrome's own zoom ladder (chrome://settings' zoom list / Chromium's
    /// `kPresetZoomFactors`). Kept identical rather than invented so a page
    /// zoomed to "125%" here matches what the same page looks like at 125% in
    /// Chrome. Must stay sorted ascending and must contain `defaultFactor`.
    static let steps: [Double] = [
        0.25, 0.33, 0.50, 0.67, 0.75, 0.80, 0.90,
        1.00,
        1.10, 1.25, 1.50, 1.75, 2.00, 2.50, 3.00, 4.00, 5.00,
    ]

    /// Chromium's zoom base. Not configurable and not a coincidence: the
    /// engine-side APIs (CefBrowserHost::SetZoomLevel, and Blink underneath
    /// WKWebView's own linear pageZoom) define level in these units.
    private static let base: Double = 1.2

    /// Comparisons against `steps` are all "strictly past this rung", so a
    /// factor that is the rung (within float noise) never counts as past it.
    /// 1e-6 is far below the gap between any two adjacent rungs (the tightest
    /// is 0.05) and far above the rounding error of pow/log round-trips.
    private static let epsilon: Double = 1e-6

    /// The logarithmic level for a scale factor. `defaultFactor` is special-
    /// cased to a literal 0 rather than `log(1.0)/log(1.2)`: both engines
    /// treat 0 as "the default zoom" specifically (CEF's own doc comment says
    /// "specify 0.0 to reset the zoom level to the default"), so ⌘0 must send
    /// an exact 0 and not a value that merely rounds to it.
    static func level(forFactor factor: Double) -> Double {
        factor == defaultFactor ? 0 : log(factor) / log(base)
    }

    /// The scale factor for a logarithmic level -- the inverse of
    /// `level(forFactor:)`.
    static func factor(forLevel level: Double) -> Double {
        pow(base, level)
    }

    /// The next rung up, or `factor` unchanged if it is already at (or past)
    /// the top of the ladder.
    static func stepUp(from factor: Double) -> Double {
        steps.first { $0 > factor + epsilon } ?? max(factor, steps[steps.count - 1])
    }

    /// The next rung down, or `factor` unchanged if it is already at (or
    /// below) the bottom of the ladder.
    static func stepDown(from factor: Double) -> Double {
        steps.last { $0 < factor - epsilon } ?? min(factor, steps[0])
    }

    /// "100%", "125%", "33%" -- the user-facing rendering of a factor.
    static func percentLabel(for factor: Double) -> String {
        "\(Int((factor * 100).rounded()))%"
    }
}
