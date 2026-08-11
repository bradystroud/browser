import AppKit

/// Handles "Copy Image" and "Copy Image Link" (browser-5kq.13), triggered
/// from `Tab.engineTabDidRequestCopyImage(imageURL:pageURL:)` /
/// `Tab.engineTabDidRequestCopyImageLink(imageURL:)` -- the two native
/// context-menu commands `BRWClientHandler` adds over an `<img>` element,
/// alongside the "Look Up Image" one browser-5kq.2 established (see
/// `VisualLookUpController`, which shares this entry-point shape).
///
/// The interesting half is where the *bytes* come from. A `URLSession` fetch
/// from the app process -- what `VisualLookUpController` does -- shares none
/// of the page's cookies, so any auth-gated image silently 403s or comes
/// back as a login-page placeholder even though the user can plainly see the
/// real image on screen. "Copy Image" therefore goes through
/// `EngineTab.downloadImage(url:completion:)`, which for the CEF engine is
/// `CefBrowserHost::DownloadImage` -- a fetch performed by the *renderer*,
/// from the tab's own request context, with the page's cookies and correct
/// initiator, and served out of the browser cache when the image is already
/// loaded. See `docs/ai-tasks/copy-image-notes.md` for exactly which image
/// cases that does and does not cover; notably it defeats CORS (a
/// restriction that exists only at the JS/DOM layer) but returns a decoded
/// bitmap, so an animated GIF arrives as a single still frame.
enum ImageCopyController {
    /// "Copy Image Link": the image's own source URL as a string. Nothing is
    /// fetched, so this works for every image, including ones "Copy Image"
    /// can't get bytes for.
    ///
    /// A `data:` URL is deliberately still copied verbatim rather than
    /// suppressed -- it is genuinely the image's address, it round-trips
    /// back into an address bar, and silently copying nothing would be
    /// worse than copying something long.
    @discardableResult
    static func copyImageLink(imageURL: String, to pasteboard: NSPasteboard = .general) -> Bool {
        guard !imageURL.isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(imageURL, forType: .string)
    }

    /// "Copy Image": asks `tab` for the image's bytes, then puts them on the
    /// pasteboard. Asynchronous -- the download is a real (usually
    /// cache-served) engine-side fetch -- and shows an alert on failure
    /// rather than leaving the user with a pasteboard that silently didn't
    /// change.
    static func copyImage(imageURL: String, tab: EngineTab?, to pasteboard: NSPasteboard = .general) {
        guard !imageURL.isEmpty, let tab else {
            showFailureAlert()
            return
        }
        tab.downloadImage(url: imageURL) { pngData, httpStatusCode in
            if let pngData, writeImage(pngData: pngData, imageURL: imageURL, to: pasteboard) {
                return
            }
            NSLog("Browser: Copy Image failed for %@ (HTTP %ld)", imageURL, httpStatusCode)
            showFailureAlert()
        }
    }

    /// The pasteboard half of `copyImage` above, split out so it can be
    /// exercised with known-good bytes and no live tab.
    ///
    /// Three flavors are written, most specific first, so each paste target
    /// can take what it understands: PNG (lossless, keeps alpha -- what
    /// Messages/Notes/Preview take), TIFF (the classic AppKit image type
    /// some older apps ask for by name), and the source URL as plain text
    /// (so pasting into a text field or terminal gives the link rather than
    /// nothing). Declaring the image types *before* `.string` matters:
    /// `NSPasteboard` resolves a reader's request in the order types were
    /// declared, so an image-capable target never falls through to the URL.
    @discardableResult
    static func writeImage(pngData: Data, imageURL: String, to pasteboard: NSPasteboard = .general) -> Bool {
        guard let image = NSImage(data: pngData) else { return false }
        var types: [NSPasteboard.PasteboardType] = [.png, .tiff]
        if !imageURL.isEmpty {
            types.append(.string)
        }
        // declareTypes both clears the pasteboard and fixes the type order;
        // no separate clearContents() call.
        pasteboard.declareTypes(types, owner: nil)
        var wroteAnImage = pasteboard.setData(pngData, forType: .png)
        if let tiff = image.tiffRepresentation {
            wroteAnImage = pasteboard.setData(tiff, forType: .tiff) || wroteAnImage
        }
        if !imageURL.isEmpty {
            pasteboard.setString(imageURL, forType: .string)
        }
        return wroteAnImage
    }

    private static func showFailureAlert() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Couldn't Copy This Image"
        alert.informativeText =
            "The image data couldn't be read. Use \"Copy Image Link\" to copy its address instead."
        alert.runModal()
    }
}
