import AppKit
import WebKit
import ObjectiveC.runtime

/// EngineTabAutomation for a WKWebView.
///
/// Clicks and keys are real AppKit events handed straight to the web view,
/// never posted to the window or the system: the page gets trusted events
/// with their default actions, while the real pointer, keyboard focus and
/// the active app stay as the user left them. Mouse moves are the
/// exception: WebKit drops them while its window is not key, so hover is
/// DOM events dispatched by page script, and CSS `:hover` does not apply.
/// Text goes in through `execCommand('insertText')`, which fires the same
/// beforeinput/input events typing does.
///
/// Screenshots are `takeSnapshot`, and a screencast is snapshots taken on a
/// timer, since WebKit has no repaint-driven frame stream. A full-page
/// screenshot is the page scrolled a viewport at a time and the snapshots
/// stitched, since `takeSnapshot` only ever sees the viewport: content the
/// page fixes to the viewport appears once per strip.
final class WebKitAutomation: EngineTabAutomation {
    private weak var webView: WKWebView?
    private var screencastTimer: Timer?
    private var screencastFrameInFlight = false
    private let encodeQueue = DispatchQueue(label: "com.browser.WebKitAutomation.encode")
    var dialogHandler: ((EngineAutomationDialog) -> EngineAutomationDialogAnswer)?

    static let screencastFramesPerSecond: Double = 15
    /// How long to wait for WebKit to report input handled before giving
    /// up waiting; a page that hangs should not hang the command too.
    private static let inputSettleTimeout: TimeInterval = 5

    init(webView: WKWebView) {
        self.webView = webView
    }

    /// WebKit's popup blocker reads the preferences, which a tab shares only
    /// with the popups it opens. An extension's page shares them with every
    /// page of that extension, so it is never changed there.
    var allowsPopupsWithoutGesture: Bool {
        get { webView?.configuration.preferences.javaScriptCanOpenWindowsAutomatically ?? false }
        set {
            // WebKitExtensionManager.pageScheme, which needs macOS 15.4.
            guard let webView, webView.url?.scheme != "chrome-extension" else { return }
            webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically = newValue
        }
    }

    deinit {
        screencastTimer?.invalidate()
    }

    // MARK: - Script

    /// Runs `body` (a function body; `args` are its named arguments) in the
    /// page's own world, awaiting a returned promise.
    private func call(
        _ body: String,
        _ args: [String: Any] = [:],
        completion: @escaping (Result<Any?, EngineAutomationError>) -> Void
    ) {
        guard let webView else { return completion(.failure(EngineAutomationError("the page closed"))) }
        webView.callAsyncJavaScript(body, arguments: args, in: nil, in: .page) { result in
            switch result {
            case .success(let value):
                completion(.success(value is NSNull ? nil : value))
            case .failure(let error):
                let info = (error as NSError).userInfo
                let message = info["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
                completion(.failure(EngineAutomationError(message)))
            }
        }
    }

    private func callVoid(_ body: String, _ args: [String: Any], completion: @escaping (Result<Void, EngineAutomationError>) -> Void) {
        call(Self.input + body, args) { completion($0.map { _ in () }) }
    }

    /// An agent window is usually covered by other windows, or off screen
    /// for a scratch instance. WebKit counts an occluded view as hidden and
    /// stops its animations, timers and painting, so snapshots go stale and
    /// a drawn cursor freezes mid-move. Private SPI, checked at runtime,
    /// and only for agent pages; without it, keep the window uncovered.
    private static let occlusionDetectionSelector = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")

    func setExactViewport(_ size: CGSize, completion: @escaping (Result<Void, EngineAutomationError>) -> Void) {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              size.width.rounded() == size.width, size.height.rounded() == size.height else {
            return completion(.failure(EngineAutomationError("exact viewport dimensions must be positive whole CSS pixels")))
        }
        guard let webView else { return completion(.failure(EngineAutomationError("the page closed"))) }
        let selector = NSSelectorFromString("_setOverrideDeviceScaleFactor:")
        guard let method = class_getInstanceMethod(WKWebView.self, selector),
              method_getNumberOfArguments(method) == 3,
              let argumentType = method_copyArgumentType(method, 2) else {
            return completion(.failure(EngineAutomationError("this macOS WebKit lacks native 1x capture; use the CEF engine for an exact viewport")))
        }
        let returnType = method_copyReturnType(method)
        defer { free(returnType); free(argumentType) }
        guard String(cString: returnType) == "v", String(cString: argumentType) == "d" else {
            return completion(.failure(EngineAutomationError("this macOS WebKit has an unsupported native capture-density API; use the CEF engine for an exact viewport")))
        }
        typealias Setter = @convention(c) (AnyObject, Selector, Double) -> Void
        let setter = unsafeBitCast(method_getImplementation(method), to: Setter.self)
        // Changing density leaves page zoom, fixed layout and mobile layout alone.
        setter(webView, selector, 1)
        completion(.success(()))
    }

    func prepare(completion: @escaping (Result<Void, EngineAutomationError>) -> Void) {
        if let webView, webView.responds(to: Self.occlusionDetectionSelector) {
            typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
            let setter = unsafeBitCast(webView.method(for: Self.occlusionDetectionSelector), to: Setter.self)
            setter(webView, Self.occlusionDetectionSelector, false)
        }
        completion(.success(()))
    }

    func evaluate(_ expression: String, completion: @escaping (Result<Any?, EngineAutomationError>) -> Void) {
        call("return await (\n\(expression)\n);", completion: completion)
    }

    // MARK: - Input

    /// Helpers every input script starts with: the element at a point, and
    /// the deep active element, both into open shadow roots and same-origin
    /// frames.
    private static let input = #"""
        const at = (x, y) => {
          let doc = document, el = document.elementFromPoint(x, y);
          for (;;) {
            if (el && el.shadowRoot) {
              const inner = el.shadowRoot.elementFromPoint(x, y);
              if (inner && inner !== el) { el = inner; continue; }
            }
            if (el && el.tagName === 'IFRAME') {
              let inner = null;
              try { inner = el.contentDocument; } catch (e) {}
              if (inner) {
                const r = el.getBoundingClientRect();
                x -= r.left + el.clientLeft; y -= r.top + el.clientTop;
                doc = inner; el = inner.elementFromPoint(x, y);
                continue;
              }
            }
            break;
          }
          return {el: el || doc.body, x, y};
        };
        const active = () => {
          let el = document.activeElement;
          for (;;) {
            if (el && el.shadowRoot && el.shadowRoot.activeElement) { el = el.shadowRoot.activeElement; continue; }
            let inner = null;
            if (el && el.tagName === 'IFRAME') { try { inner = el.contentDocument; } catch (e) {} }
            if (inner && inner.activeElement) { el = inner.activeElement; continue; }
            break;
          }
          return el && el !== el.ownerDocument.documentElement ? el : document.body;
        };
        const mouse = (el, type, x, y) => {
          const view = el.ownerDocument.defaultView;
          const init = {bubbles: true, cancelable: true, composed: true, view, clientX: x, clientY: y};
          const ctor = type.startsWith('pointer') ? view.PointerEvent : view.MouseEvent;
          if (type.startsWith('pointer')) Object.assign(init, {pointerId: 1, pointerType: 'mouse', isPrimary: true});
          return el.dispatchEvent(new ctor(type, init));
        };

        """#

    func mouseMove(to point: CGPoint, completion: @escaping (Result<Void, EngineAutomationError>) -> Void) {
        callVoid("""
            const hit = at(x, y);
            for (const type of ['pointerover', 'pointerenter', 'mouseover', 'mouseenter', 'pointermove', 'mousemove']) mouse(hit.el, type, hit.x, hit.y);
            """, ["x": point.x, "y": point.y], completion: completion)
    }

    func click(at point: CGPoint, clickCount: Int, completion: @escaping (Result<Void, EngineAutomationError>) -> Void) {
        // Hover first, as a real pointer would on its way to the target.
        mouseMove(to: point) { [weak self] _ in
            guard let self, let webView = self.webView, let window = webView.window else {
                return completion(.failure(EngineAutomationError("the page has no window")))
            }
            let location = Self.windowLocation(of: point, in: webView)
            for count in 1...max(1, clickCount) {
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    guard let event = NSEvent.mouseEvent(
                        with: type, location: location, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 0, clickCount: count, pressure: type == .leftMouseDown ? 1 : 0)
                    else { return completion(.failure(EngineAutomationError("could not make a mouse event"))) }
                    type == .leftMouseDown ? webView.mouseDown(with: event) : webView.mouseUp(with: event)
                }
            }
            self.afterPendingInput(Self.afterMouseEventsSelector) { completion(.success(())) }
        }
    }

    func scroll(at point: CGPoint, deltaX: Double, deltaY: Double, completion: @escaping (Result<Void, EngineAutomationError>) -> Void) {
        callVoid("""
            const hit = at(x, y);
            const el = hit.el;
            if (!el.dispatchEvent(new WheelEvent('wheel', {bubbles: true, cancelable: true, composed: true, clientX: hit.x, clientY: hit.y, deltaX: dx, deltaY: dy}))) return;
            // The nearest ancestor that can scroll that way takes it.
            let node = el;
            while (node && node !== node.ownerDocument.body && node !== node.ownerDocument.documentElement) {
              const style = getComputedStyle(node);
              const canY = dy && /(auto|scroll|overlay)/.test(style.overflowY) && node.scrollHeight > node.clientHeight;
              const canX = dx && /(auto|scroll|overlay)/.test(style.overflowX) && node.scrollWidth > node.clientWidth;
              if (canX || canY) { node.scrollBy(dx, dy); return; }
              node = node.parentElement;
            }
            el.ownerDocument.defaultView.scrollBy(dx, dy);
            """, ["x": point.x, "y": point.y, "dx": deltaX, "dy": deltaY], completion: completion)
    }

    func insertText(_ text: String, completion: @escaping (Result<Void, EngineAutomationError>) -> Void) {
        callVoid("""
            const el = active();
            const doc = el.ownerDocument;
            if (doc.execCommand('insertText', false, text)) return;
            // Not editable through the selection (a type execCommand skips):
            // set the value the way the field's own setter would, then say so.
            if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') {
              const start = el.selectionStart ?? el.value.length;
              const end = el.selectionEnd ?? el.value.length;
              const view = doc.defaultView;
              const proto = el.tagName === 'INPUT' ? view.HTMLInputElement.prototype : view.HTMLTextAreaElement.prototype;
              Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, el.value.slice(0, start) + text + el.value.slice(end));
              el.dispatchEvent(new view.InputEvent('input', {bubbles: true, composed: true, inputType: 'insertText', data: text}));
              return;
            }
            throw new Error('nothing editable has focus');
            """, ["text": text], completion: completion)
    }

    func pressKey(_ key: EngineAutomationKey, modifiers: EngineAutomationModifiers, completion: @escaping (Result<Void, EngineAutomationError>) -> Void) {
        guard let webView, let window = webView.window else {
            return completion(.failure(EngineAutomationError("the page has no window")))
        }
        guard let native = Self.nativeKey(for: key, modifiers: modifiers) else {
            return completion(.failure(EngineAutomationError("no Mac key for \(key.key)")))
        }
        var flags: NSEvent.ModifierFlags = native.shift ? [.shift] : []
        if modifiers.contains(.alt) { flags.insert(.option) }
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        var events: [NSEvent] = []
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: native.characters, charactersIgnoringModifiers: native.charactersIgnoringModifiers,
                isARepeat: false, keyCode: native.keyCode)
            else { return completion(.failure(EngineAutomationError("could not make a key event"))) }
            events.append(event)
        }
        // A key the page leaves unhandled comes back up the window's
        // responder chain as a command: Escape cancels whatever the window
        // is doing, and anything else beeps.
        let sink = UnhandledKeySink()
        sink.nextResponder = webView.nextResponder
        webView.nextResponder = sink
        webView.keyDown(with: events[0])
        webView.keyUp(with: events[1])
        afterPendingInput(Self.afterKeyEventsSelector) { [weak webView] in
            if let webView, webView.nextResponder === sink { webView.nextResponder = sink.nextResponder }
            completion(.success(()))
        }
    }

    /// CSS pixels from the viewport's top-left, as a point in the web view's
    /// window.
    private static func windowLocation(of point: CGPoint, in webView: WKWebView) -> NSPoint {
        let scale = max(webView.pageZoom * webView.magnification, 0.01)
        return webView.convert(NSPoint(x: point.x * scale, y: point.y * scale), to: nil)
    }

    private static let afterMouseEventsSelector = NSSelectorFromString("_doAfterProcessingAllPendingMouseEvents:")
    private static let afterKeyEventsSelector = NSSelectorFromString("_doAfterProcessingAllPendingKeyEvents:")

    /// Calls `then` once the page has handled every input event sent so
    /// far, so a command's result reflects what its input did. Private SPI,
    /// checked at runtime; without it, a short wait stands in.
    private func afterPendingInput(_ selector: Selector, then: @escaping () -> Void) {
        var called = false
        let once = {
            guard !called else { return }
            called = true
            then()
        }
        guard let webView, webView.responds(to: selector) else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: once)
            return
        }
        typealias Call = @convention(c) (AnyObject, Selector, @escaping @convention(block) () -> Void) -> Void
        let call = unsafeBitCast(webView.method(for: selector), to: Call.self)
        call(webView, selector) { DispatchQueue.main.async(execute: once) }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.inputSettleTimeout, execute: once)
    }

    private struct NativeKey {
        let keyCode: UInt16
        let characters: String
        let charactersIgnoringModifiers: String
        let shift: Bool
    }

    /// Mac virtual key codes (US layout) and the characters AppKit reports
    /// for them. A character with no key of its own is sent with the
    /// characters alone, which is what an input method does. With Shift or
    /// Option held, the characters are what the user's layout types for
    /// that chord (Option+2 is "™"), as a real press would deliver.
    private static func nativeKey(for key: EngineAutomationKey, modifiers: EngineAutomationModifiers) -> NativeKey? {
        let named: [String: (UInt16, Int)] = [
            "Enter": (36, 0x0D), "Tab": (48, 0x09), "Escape": (53, 0x1B), "Backspace": (51, 0x7F),
            "Delete": (117, 0xF728), " ": (49, 0x20),
            "ArrowLeft": (123, 0xF702), "ArrowRight": (124, 0xF703), "ArrowDown": (125, 0xF701), "ArrowUp": (126, 0xF700),
            "Home": (115, 0xF729), "End": (119, 0xF72B), "PageUp": (116, 0xF72C), "PageDown": (121, 0xF72D),
        ]
        if let (code, scalar) = named[key.key], let character = Unicode.Scalar(scalar).map(String.init) {
            return NativeKey(keyCode: code, characters: character, charactersIgnoringModifiers: character, shift: false)
        }
        guard let text = key.text, text.count == 1, let character = text.first else { return nil }
        let lower = text.lowercased()
        let shift = lower != text || modifiers.contains(.shift)
        // 0x7F has no key on any Mac keyboard, so the page sees no key code.
        let code = MacKeyboardLayout.virtualKeyCode(for: character) ?? 0x7F
        // Command and Control chords keep the plain character, as AppKit
        // reports it for a shortcut.
        let typed = modifiers.isDisjoint(with: [.command, .control])
            ? MacKeyboardLayout.typedText(for: character, shift: shift, option: modifiers.contains(.alt))
            : text
        return NativeKey(keyCode: code, characters: typed, charactersIgnoringModifiers: lower, shift: shift)
    }

    // MARK: - Capture

    func screenshot(fullPage: Bool, completion: @escaping (Result<Data, EngineAutomationError>) -> Void) {
        guard !fullPage else { return fullPageScreenshot(completion: completion) }
        snapshot { [weak self] result in
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success(let image): self?.encodePNG(image, completion: completion)
            }
        }
    }

    private func encodePNG(_ image: CGImage, completion: @escaping (Result<Data, EngineAutomationError>) -> Void) {
        encodeQueue.async {
            let png = Self.encode(image, as: .png, quality: 1)
            DispatchQueue.main.async {
                png.map { completion(.success($0)) } ?? completion(.failure(EngineAutomationError("could not encode the screenshot")))
            }
        }
    }

    /// The most viewports a full-page screenshot stitches; a page that
    /// scrolls for ever still gets a bounded image.
    static let maxFullPageViewports = 20

    private struct PageMetrics: Decodable {
        let width: Double
        let height: Double
        let viewportHeight: Double
        let scrollX: Double
        let scrollY: Double
    }

    /// Scrolls the window down one viewport at a time, snapshots each
    /// position and composes the strips at the scroll offsets the page
    /// really took, then puts the scroll position back. Stops early when the
    /// page will not scroll further, so a page whose scrolling happens in an
    /// inner element gives the viewport alone rather than twenty copies.
    private func fullPageScreenshot(completion: @escaping (Result<Data, EngineAutomationError>) -> Void) {
        call("""
            const doc = document.documentElement, body = document.body;
            return {width: innerWidth, viewportHeight: innerHeight,
                    height: Math.max(doc.scrollHeight, body ? body.scrollHeight : 0, innerHeight),
                    scrollX: scrollX, scrollY: scrollY};
            """) { [weak self] result in
            guard let self else { return completion(.failure(EngineAutomationError("the page closed"))) }
            guard case .success(let value) = result, let value, JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value),
                  let metrics = try? JSONDecoder().decode(PageMetrics.self, from: data),
                  metrics.width > 0, metrics.viewportHeight > 0 else {
                return completion(.failure(EngineAutomationError("could not measure the page")))
            }
            let height = min(metrics.height, metrics.viewportHeight * Double(Self.maxFullPageViewports))
            var strips: [(scrollY: Double, image: CGImage)] = []
            let restore = { (then: @escaping () -> Void) in
                self.call("scrollTo(x, y);", ["x": metrics.scrollX, "y": metrics.scrollY]) { _ in then() }
            }
            func capture(at offset: Double) {
                // A moment after the scroll, so lazily drawn content has
                // painted. A timer, not requestAnimationFrame: a view that
                // is not drawing (hidden, or in a test) never gets a frame.
                self.call("scrollTo(x, y); await new Promise(r => setTimeout(r, 80)); return scrollY;",
                          ["x": metrics.scrollX, "y": offset]) { [weak self] result in
                    guard let self else { return completion(.failure(EngineAutomationError("the page closed"))) }
                    let actual = (try? result.get()) as? Double ?? offset
                    if let last = strips.last, actual <= last.scrollY {
                        return restore { self.compose(strips, metrics: metrics, completion: completion) }
                    }
                    self.snapshot { [weak self] result in
                        guard let self else { return completion(.failure(EngineAutomationError("the page closed"))) }
                        guard case .success(let image) = result else {
                            return restore { completion(.failure(EngineAutomationError("the engine returned no image"))) }
                        }
                        strips.append((actual, image))
                        let next = offset + metrics.viewportHeight
                        guard next < height else { return restore { self.compose(strips, metrics: metrics, completion: completion) } }
                        capture(at: next)
                    }
                }
            }
            capture(at: 0)
        }
    }

    /// One image of the strips at their scroll offsets, scaled as the
    /// snapshots were (the screen's pixel density).
    private func compose(_ strips: [(scrollY: Double, image: CGImage)], metrics: PageMetrics, completion: @escaping (Result<Data, EngineAutomationError>) -> Void) {
        guard let first = strips.first else { return completion(.failure(EngineAutomationError("the engine returned no image"))) }
        guard strips.count > 1 else { return encodePNG(first.image, completion: completion) }
        let scale = Double(first.image.width) / metrics.width
        guard let last = strips.last else { return encodePNG(first.image, completion: completion) }
        let totalHeight = Int((last.scrollY * scale).rounded()) + last.image.height
        encodeQueue.async {
            guard let context = CGContext(
                data: nil, width: first.image.width, height: totalHeight, bitsPerComponent: 8, bytesPerRow: 0,
                space: first.image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return DispatchQueue.main.async { completion(.failure(EngineAutomationError("could not compose the screenshot"))) }
            }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: first.image.width, height: totalHeight))
            for strip in strips {
                let top = Int((strip.scrollY * scale).rounded())
                // Core Graphics draws from the bottom; the strip's top is
                // `top` pixels down from the page's top.
                let rect = CGRect(x: 0, y: totalHeight - top - strip.image.height, width: strip.image.width, height: strip.image.height)
                context.draw(strip.image, in: rect)
            }
            let png = context.makeImage().flatMap { Self.encode($0, as: .png, quality: 1) }
            DispatchQueue.main.async {
                png.map { completion(.success($0)) } ?? completion(.failure(EngineAutomationError("could not encode the screenshot")))
            }
        }
    }

    func startScreencast(
        quality: Int,
        onFrame: @escaping (Data, TimeInterval) -> Void,
        completion: @escaping (Result<Void, EngineAutomationError>) -> Void
    ) {
        guard webView != nil else { return completion(.failure(EngineAutomationError("the page closed"))) }
        stopScreencast()
        let compression = Double(quality) / 100
        let timer = Timer(timeInterval: 1 / Self.screencastFramesPerSecond, repeats: true) { [weak self] _ in
            guard let self, !self.screencastFrameInFlight else { return }
            self.screencastFrameInFlight = true
            let timestamp = Date().timeIntervalSince1970
            self.snapshot { [weak self] result in
                guard let self else { return }
                guard case .success(let image) = result else {
                    self.screencastFrameInFlight = false
                    return
                }
                self.encodeQueue.async {
                    let jpeg = Self.encode(image, as: .jpeg, quality: compression)
                    DispatchQueue.main.async {
                        self.screencastFrameInFlight = false
                        guard self.screencastTimer != nil, let jpeg else { return }
                        onFrame(jpeg, timestamp)
                    }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        screencastTimer = timer
        timer.fire()
        completion(.success(()))
    }

    func stopScreencast() {
        screencastTimer?.invalidate()
        screencastTimer = nil
    }

    /// The visible page at the screen's pixel density.
    private func snapshot(completion: @escaping (Result<CGImage, EngineAutomationError>) -> Void) {
        guard let webView else { return completion(.failure(EngineAutomationError("the page closed"))) }
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        webView.takeSnapshot(with: configuration) { image, error in
            guard let image else {
                return completion(.failure(EngineAutomationError(error?.localizedDescription ?? "the engine returned no image")))
            }
            var rect = CGRect(origin: .zero, size: image.size)
            let pixels = image.representations
                .compactMap { $0 as? NSBitmapImageRep }
                .map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) }
                .max { $0.width < $1.width }
            if let pixels, pixels.width > rect.width { rect.size = pixels }
            guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
                return completion(.failure(EngineAutomationError("the engine returned an unreadable image")))
            }
            completion(.success(cgImage))
        }
    }

    private static func encode(_ image: CGImage, as type: NSBitmapImageRep.FileType, quality: Double) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: type, properties: type == .jpeg ? [.compressionFactor: quality] : [:])
    }
}

/// Takes the commands WebKit passes up the responder chain for a key the
/// page did not handle, for as long as it sits after the web view.
private final class UnhandledKeySink: NSResponder {
    override func doCommand(by selector: Selector) {}
    override func keyDown(with event: NSEvent) {}
    override func keyUp(with event: NSEvent) {}
    override func cancelOperation(_ sender: Any?) {}
    override func noResponder(for eventSelector: Selector) {}
}
