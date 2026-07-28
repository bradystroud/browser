import Foundation

/// One-shot (not document-start-injected) script for View > Enter Picture in
/// Picture (browser-7jz.1) -- executed via Tab.executeJavaScript(_:)
/// exactly like Reader mode's Readability.js injection, since this is a
/// single user-triggered action, not something that needs to run on every
/// navigation. Fire-and-forget: no JS->native response needed (this only
/// ever *starts* a PiP session; the resulting floating window is entirely
/// Chromium's own native UI, unrelated to anything this bridge renders),
/// so there's no reason to route this through PageMessageDispatcher.
///
/// Chromium's own context menu already offers a native "Picture in
/// Picture" entry for any `<video>` (this app has no CefContextMenuHandler
/// override, so CEF's stock menu is used unmodified -- see bd show
/// browser-7jz.1's notes) -- this script is purely a second, menu-driven
/// entry point to the exact same standard `HTMLVideoElement.
/// requestPictureInPicture()` web API, for a page where the user would
/// rather use View > Enter Picture in Picture than right-click the video
/// itself.
enum PictureInPictureScript {
    static let toggleSource = """
    (function() {
      if (document.pictureInPictureElement) {
        document.exitPictureInPicture().catch(function() {});
        return;
      }
      function isPlaying(video) {
        return video.currentTime > 0 && !video.paused && !video.ended && video.readyState > 2;
      }
      var videos = Array.prototype.slice.call(document.querySelectorAll('video'));
      var target = videos.filter(isPlaying)[0] || videos[0];
      if (!target || typeof target.requestPictureInPicture !== 'function') { return; }
      target.requestPictureInPicture().catch(function() {});
    })();
    """
}
