import AppKit

/// Handles "Download Image" (browser-5kq.14), the third of the native
/// context-menu commands `BRWClientHandler` adds over an `<img>` element
/// (see `ImageCopyController` for the other two).
///
/// Deliberately tiny, and that is the design: the saved file has to behave
/// like every other download -- a row in `DownloadStore`, a line in the
/// Downloads window, live progress, cancel, reveal -- so this does *not*
/// fetch bytes and write them itself. It asks the engine to start a real
/// download originating from the tab, which arrives at the same
/// `OnBeforeDownload` → `Tab.engineTabDidBeginDownload` →
/// `DownloadCoordinator.beginDownload` → `DownloadStore` path a
/// page-initiated download already used. Everything downstream -- the
/// destination directory, the never-overwrite unique-filename rule, the
/// progress updates -- is shared with page downloads by construction rather
/// than reimplemented here.
///
/// Because the request originates from the tab it also carries the profile's
/// cookies and a referrer, the same property that makes `ImageCopyController`
/// work on auth-gated images.
///
/// See `docs/ai-tasks/copy-image-notes.md` for which URL schemes this
/// actually covers (`data:` and `blob:` are the interesting ones) and where
/// the filename comes from.
enum ImageDownloadController {
    static func downloadImage(imageURL: String, tab: EngineTab?) {
        guard !imageURL.isEmpty, let tab else {
            NSLog("Browser: Download Image had no image URL or no live tab")
            return
        }
        tab.startDownload(url: imageURL)
    }
}
