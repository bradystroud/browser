import Foundation

/// A fixed device viewport preset for Responsive Design Mode
/// (browser-6hi.2) -- CDP's Emulation.setDeviceMetricsOverride takes
/// exactly these four values (see BRWBrowser.h's
/// -setResponsiveDesignModeWithWidth:height:deviceScaleFactor:mobile: for
/// why this works without opening DevTools' own UI at all -- CEF documents
/// that ExecuteDevToolsMethod doesn't require an active DevTools
/// instance). Sizes and scale factors are Apple's own published device
/// specifications (logical points and devicePixelRatio), not guesses.
struct ResponsiveDevicePreset {
    let name: String
    let width: Int
    let height: Int
    let deviceScaleFactor: Double
    let mobile: Bool

    static let all: [ResponsiveDevicePreset] = [
        ResponsiveDevicePreset(name: "iPhone SE", width: 375, height: 667, deviceScaleFactor: 2, mobile: true),
        ResponsiveDevicePreset(name: "iPhone 14", width: 390, height: 844, deviceScaleFactor: 3, mobile: true),
        ResponsiveDevicePreset(name: "iPhone 14 Pro Max", width: 430, height: 932, deviceScaleFactor: 3, mobile: true),
        ResponsiveDevicePreset(name: "iPad Mini", width: 744, height: 1133, deviceScaleFactor: 2, mobile: true),
        ResponsiveDevicePreset(name: "iPad Pro 12.9\"", width: 1024, height: 1366, deviceScaleFactor: 2, mobile: true),
    ]
}
