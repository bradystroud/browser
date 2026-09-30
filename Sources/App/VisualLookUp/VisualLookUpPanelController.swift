import AppKit
import VisionKit

/// The panel VisualLookUpController shows the analysis results in
/// (browser-5kq.2). This app's own panel, not an overlay drawn on top of
/// CEF's own rendering of the page -- VisionKit's macOS interaction model
/// (`ImageAnalysisOverlayView`, an `NSView` subclass you display the image
/// through and that renders/handles its own Live Text selection and Visual
/// Look Up UI directly) requires a real, ordinary NSView in a real window
/// to attach to; there's no way to composite it into CEF's own windowless/
/// windowed rendering surface, which CEF owns outright and this bridge
/// never gets to draw arbitrary NSViews inside of. A dedicated panel with a
/// plain `NSImageView` (showing the actual pixels) plus an
/// `ImageAnalysisOverlayView` sized to match it (handling the interactive
/// parts) is the correct, fully-supported way to use this API on macOS --
/// see that class's own doc comment for exactly how the two views relate
/// (`trackingImageView`).
///
/// Note this is a genuinely different API from `ImageAnalysisInteraction`,
/// which many WWDC talks/sample projects (mostly iOS-focused) show attached
/// directly to an existing UIImageView via `addInteraction(_:)` --
/// `ImageAnalysisInteraction` is iOS/iPadOS/Mac-Catalyst/visionOS only (per
/// Apple's own documented platform availability), not available to native
/// AppKit at all. `ImageAnalysisOverlayView` is the real macOS (13.0+)
/// equivalent, and was confirmed as such by fetching Apple's own current
/// documentation rather than assumed from general VisionKit familiarity --
/// see docs/ai-tasks/visual-look-up-notes.md for that investigation.
@available(macOS 13.0, *)
@MainActor
final class VisualLookUpPanelController: NSObject {
    static let shared = VisualLookUpPanelController()

    private static let maxDimension: CGFloat = 640
    private static let margin: CGFloat = 16

    private var panel: NSPanel?
    private var imageView: NSImageView?
    private var overlayView: ImageAnalysisOverlayView?

    private override init() {}

    func show(image: NSImage, analysis: ImageAnalysis) {
        let displaySize = Self.displaySize(for: image.size)
        let contentSize = NSSize(width: displaySize.width + Self.margin * 2, height: displaySize.height + Self.margin * 2)

        let panel = self.panel ?? Self.makePanel()
        self.panel = panel
        panel.setContentSize(contentSize)

        let imageView = self.imageView ?? Self.makeImageView()
        self.imageView = imageView
        imageView.frame = NSRect(x: Self.margin, y: Self.margin, width: displaySize.width, height: displaySize.height)
        imageView.image = image

        let overlayView = self.overlayView ?? Self.makeOverlayView(trackingImageView: imageView)
        self.overlayView = overlayView
        overlayView.frame = imageView.frame

        if let contentView = panel.contentView {
            if imageView.superview !== contentView { contentView.addSubview(imageView) }
            if overlayView.superview !== contentView { contentView.addSubview(overlayView) }
        }

        overlayView.analysis = analysis
        overlayView.preferredInteractionTypes = .automatic

        panel.center()
        panel.makeKeyAndOrderFront(nil)
        AppActivation.activate()
    }

    private static func displaySize(for imageSize: NSSize) -> NSSize {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return NSSize(width: maxDimension, height: maxDimension)
        }
        let aspectRatio = imageSize.width / imageSize.height
        if imageSize.width >= imageSize.height {
            let width = min(imageSize.width, maxDimension)
            return NSSize(width: width, height: width / aspectRatio)
        } else {
            let height = min(imageSize.height, maxDimension)
            return NSSize(width: height * aspectRatio, height: height)
        }
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: maxDimension, height: maxDimension),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Look Up Image"
        panel.isReleasedWhenClosed = false
        return panel
    }

    private static func makeImageView() -> NSImageView {
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.autoresizingMask = []
        return imageView
    }

    /// `trackingImageView` tells the overlay which NSImageView's image/
    /// bounds it should track for coordinate mapping -- see this class's
    /// own doc comment on why displaySize's exact-aspect-ratio sizing means
    /// the tracked view's full frame is always genuine image content, with
    /// no letterboxing `contentsRect` would otherwise need to account for.
    private static func makeOverlayView(trackingImageView: NSImageView) -> ImageAnalysisOverlayView {
        let overlayView = ImageAnalysisOverlayView()
        overlayView.trackingImageView = trackingImageView
        overlayView.autoresizingMask = []
        return overlayView
    }
}
