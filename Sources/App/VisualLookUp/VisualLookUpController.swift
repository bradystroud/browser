import AppKit
import VisionKit

/// Handles "Look Up Image" (browser-5kq.2), triggered from
/// -[Tab engineTabDidRequestVisualLookUp:pageURL:] (the native context-menu
/// command BRWClientHandler adds when right-clicking an image -- see that
/// class's own doc comment for why CefContextMenuHandler, unlike
/// CefCommandHandler, works fine for this app's Alloy-style windows).
///
/// Getting the actual image bytes deliberately does NOT go through page JS
/// at all -- no canvas re-encoding, no cefQuery round trip. CEF's own
/// CefContextMenuParams already hands over the image's source URL
/// (GetSourceUrl()) directly; this fetches that URL itself, natively,
/// which sidesteps a real problem the JS-canvas approach would have hit: a
/// `<canvas>` re-encoding a cross-origin image without permissive CORS
/// headers throws a SecurityError ("tainted canvas") -- a restriction that
/// exists purely at the JS/DOM layer and doesn't apply to an ordinary
/// native URLSession fetch of the same URL. A `data:` URL (an inline
/// image) needs no fetch at all -- its bytes are decoded directly from the
/// URL string itself.
///
/// Known gap (documented, not silently swallowed): a `blob:` URL -- an
/// image whose bytes only ever existed as a JS-side object URL, never a
/// real network resource -- can't be fetched this way at all; this shows
/// the same graceful failure alert as any other fetch failure. Doing
/// better than that would need falling back to the JS/canvas approach for
/// that specific case, deferred past v1 (see docs/ai-tasks/
/// visual-look-up-notes.md's Deviations).
@available(macOS 13.0, *)
enum VisualLookUpController {
    enum LookUpError: Error {
        case invalidDataURL
        case invalidURL
        case decodingFailed
    }

    static func handleRequest(imageURL: String, pageURL: String) {
        guard ImageAnalyzer.isSupported else {
            // Shouldn't normally happen -- BRWBrowser.setVisualLookUpAvailable(_:)
            // is only ever called with `true` when this same check already
            // passed at launch -- but a Mac's support could theoretically
            // change between launch and this click (e.g. a race with some
            // system update), so this is checked again rather than assumed.
            showAlert(title: "Visual Look Up Isn't Available", message: "This Mac doesn't support image analysis.")
            return
        }

        Task {
            do {
                let data = try await fetchImageData(imageURL: imageURL, pageURL: pageURL)
                guard let image = NSImage(data: data) else {
                    throw LookUpError.decodingFailed
                }
                let analysis = try await ImageAnalyzer().analyze(
                    image, orientation: .up,
                    configuration: ImageAnalyzer.Configuration([.text, .visualLookUp])
                )
                await MainActor.run {
                    VisualLookUpPanelController.shared.show(image: image, analysis: analysis)
                }
            } catch {
                await MainActor.run {
                    showAlert(
                        title: "Couldn't Look Up This Image",
                        message: "The image couldn't be loaded or analyzed. \(error.localizedDescription)"
                    )
                }
            }
        }
    }

    private static func fetchImageData(imageURL: String, pageURL: String) async throws -> Data {
        if imageURL.hasPrefix("data:") {
            guard let commaIndex = imageURL.firstIndex(of: ","),
                  let data = Data(base64Encoded: String(imageURL[imageURL.index(after: commaIndex)...]))
            else {
                throw LookUpError.invalidDataURL
            }
            return data
        }

        guard let url = URL(string: imageURL) else {
            throw LookUpError.invalidURL
        }
        var request = URLRequest(url: url)
        // Some hosts reject an image request with no Referer header --
        // sending the containing page's URL matches what the browser
        // itself sent when it originally loaded the image. This alone
        // doesn't help a login-gated image (no session cookies are
        // forwarded -- see the notes doc's Deviations), just the more
        // common "hotlink protection checks Referer" case.
        if !pageURL.isEmpty {
            request.setValue(pageURL, forHTTPHeaderField: "Referer")
        }
        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    }

    private static func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
