import Foundation

/// The in-page half of offline article capture (browser-56p): runs
/// Readability over a *clone* of the live document and sends the extracted
/// article up the generic page-message channel.
///
/// Reader mode runs the same extractor but throws the result straight at
/// `document.write`, because it only ever needs the article on screen. This
/// needs the article in native code instead, which is why it goes through
/// `window.cefQuery` rather than `executeJavaScript`: that call has no
/// result path at all (see BRWBrowser.h), and the marker-attribute-plus-
/// getPageSource trick Reader mode uses for its one boolean would mean
/// round-tripping an entire article through the page's own HTML.
///
/// **This script never touches the live DOM.** Reader mode replaces the
/// document because the user asked to read it that way; saving a page must
/// leave it exactly as it was, so everything happens on the clone.
enum ReadingListCaptureScript {
    /// The page-message `"type"` this script sends, and what
    /// ReadingListCoordinator registers for with PageMessageDispatcher.
    static let messageType = "readingListArticle"

    /// Sent when extraction produced nothing usable, so the native side can
    /// stop waiting rather than leaving the item pending forever.
    static let failureReason = "unreadable"

    /// Mirrors `ReadingListStore.maximumArticleBytes`. Enforced here too so
    /// an article that will be refused anyway is never serialized, sent
    /// across the process boundary and then thrown away.
    private static let maximumArticleBytes = ReadingListStore.maximumArticleBytes

    static func source(url: String, title: String) -> String {
        ReaderScripts.readabilityJS + "\n" + """
        (function() {
          var PAGE_URL = \(jsonString(url));
          var PAGE_TITLE = \(jsonString(title));
          var MAX_BYTES = \(maximumArticleBytes);
          var RETRY_MS = 600;
          var MAX_ATTEMPTS = 8;

          // Retries until the native side acks, the same shape (and for the
          // same reason) as PasswordDetectionScript.sendReliable -- a query
          // sent before this tab's channel is wired is dropped in silence.
          function send(payload) {
            var attempts = 0;
            var acked = false;
            function attempt() {
              if (acked || attempts >= MAX_ATTEMPTS) { return; }
              attempts++;
              try {
                window.cefQuery({
                  request: JSON.stringify(payload),
                  onSuccess: function() { acked = true; },
                  onFailure: function() { acked = true; }
                });
              } catch (e) {}
              setTimeout(function() { if (!acked) { attempt(); } }, RETRY_MS);
            }
            attempt();
          }

          function fail() {
            send({ type: '\(messageType)', url: PAGE_URL, ok: false, reason: '\(failureReason)' });
          }

          function byteLength(s) {
            try { return new TextEncoder().encode(s).length; } catch (e) { return s.length * 4; }
          }

          // Saving a page while Reader mode is showing would otherwise
          // extract an extraction: Reader mode replaced the live document
          // with its own template, so Readability would parse that instead
          // of the article. The template is already the clean article, so
          // take it directly -- a better result than re-parsing it, and it
          // covers re-saving an article opened from the reading list too,
          // since that page uses the same markup.
          function fromReaderDocument() {
            var content = document.querySelector('.brw-reader-content');
            if (!content) { return null; }
            var titleEl = document.querySelector('.brw-reader-title');
            var bylineEl = document.querySelector('.brw-reader-byline');
            return {
              content: content.innerHTML,
              title: titleEl ? titleEl.textContent : '',
              byline: bylineEl ? bylineEl.textContent : '',
              excerpt: ''
            };
          }

          try {
            // Readability mutates the document it is given, so it gets a
            // copy. The clone keeps the live document's baseURI, which is
            // what lets Readability rewrite relative links and image
            // sources to absolute ones -- without that the saved article
            // would render from a data: URL with every link pointing
            // nowhere.
            var article = fromReaderDocument() || new Readability(document.cloneNode(true)).parse();
            if (!article || !article.content) { fail(); return; }
            if (byteLength(article.content) > MAX_BYTES) { fail(); return; }
            send({
              type: '\(messageType)',
              url: PAGE_URL,
              ok: true,
              title: article.title || PAGE_TITLE || '',
              byline: article.byline || '',
              excerpt: article.excerpt || '',
              content: article.content
            });
          } catch (e) {
            fail();
          }
        })();
        """
    }

    private static func jsonString(_ s: String) -> String {
        guard let data = try? JSONEncoder().encode(s), let json = String(data: data, encoding: .utf8) else {
            return "''"
        }
        return json
    }
}
