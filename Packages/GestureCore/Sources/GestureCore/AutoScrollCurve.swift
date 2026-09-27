import Foundation

/// How fast middle-click autoscroll moves the page for a given pointer
/// offset from the origin mark. The page script embeds `javaScriptFunction`,
/// generated from the same constants, so the Swift function is what the
/// tests pin down and the page cannot drift from it.
public enum AutoScrollCurve {
    /// Pointer offset, in CSS pixels, inside which nothing moves, so a
    /// hand resting near the mark holds the page still.
    public static let deadZone = 12.0
    public static let divisor = 10.0
    public static let exponent = 1.4
    /// Top speed in CSS pixels per second.
    public static let maxSpeed = 3600.0
    /// Scale that turns the curve's per-frame value at 60 Hz into pixels
    /// per second, so the page moves at the same speed on a 120 Hz display.
    public static let framesPerSecond = 60.0

    /// Held down, moved past the dead zone and let go after this long: the
    /// press was a drag, and letting go stops the scrolling. A shorter
    /// press is a click, and scrolling continues until the next click.
    public static let dragReleaseDelay: TimeInterval = 0.25

    /// Signed speed, in CSS pixels per second, for a signed offset.
    public static func speed(offset: Double) -> Double {
        let beyond = abs(offset) - deadZone
        guard beyond > 0 else { return 0 }
        let perSecond = pow(beyond / divisor, exponent) * framesPerSecond
        return (offset < 0 ? -1 : 1) * min(maxSpeed, perSecond)
    }

    /// `function(offset) -> px per second`, the JavaScript twin of `speed`.
    public static var javaScriptFunction: String {
        """
        function (d) {
          var a = Math.abs(d) - \(deadZone);
          if (a <= 0) { return 0; }
          return (d < 0 ? -1 : 1) * Math.min(\(maxSpeed), Math.pow(a / \(divisor), \(exponent)) * \(framesPerSecond));
        }
        """
    }
}
