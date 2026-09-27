import Foundation
import WebKit

/// WebKit's half of EngineTab.setSiteStyleSheets(_:): a document-start
/// WKUserScript, so a site's sheet is in the document before WebKit parses
/// the first byte of it and nothing it hides is ever painted.
///
/// The script carries the whole site -> sheet map and picks by
/// `location.hostname`, since it is installed before anyone knows where the
/// tab will go. It runs in `.defaultClient`, not `.page`: the map covers
/// every site this profile has hidden anything on, and no page may read
/// which other sites those are. The `<style>` element it writes is shared
/// DOM, so it applies to the page all the same.
final class WebKitSiteStyleSheets {
    private var installedScript: WKUserScript?

    func setSheets(_ sheetsBySite: [String: String], in webView: WKWebView) {
        let userContentController = webView.configuration.userContentController
        let replacement = sheetsBySite.isEmpty ? nil : WKUserScript(
            source: SiteStyleSheetScript.forDocumentLocation(sheets: sheetsBySite),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: .defaultClient)

        // WKUserContentController cannot remove a single script. Rebuild the
        // list with ours swapped in place, so every other feature's scripts
        // keep their content worlds and injection order.
        if installedScript != nil || replacement != nil {
            let others = userContentController.userScripts.filter { $0 !== installedScript }
            userContentController.removeAllUserScripts()
            others.forEach(userContentController.addUserScript)
            if let replacement {
                userContentController.addUserScript(replacement)
            }
            installedScript = replacement
        }

        // The live document chooses by its own location: webView.url is
        // already a pending navigation's URL while the old page is showing.
        webView.evaluateJavaScript(SiteStyleSheetScript.forDocumentLocation(sheets: sheetsBySite), in: nil, in: .defaultClient) { result in
            if case .failure(let error) = result {
                NSLog("Browser: WebKit site style sheet update failed: %@", error.localizedDescription)
            }
        }
    }
}

extension WebKitTab {
    func setSiteStyleSheets(_ sheetsBySite: [String: String]) {
        siteStyleSheets.setSheets(sheetsBySite, in: webView)
    }
}
