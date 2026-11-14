import Foundation

/// EngineTabAutomation over the Chrome DevTools protocol, for an engine that
/// can send protocol commands to one tab's own page session (CEF's
/// BRWBrowser -executeAutomationMethod:). Knows protocol method names and
/// nothing about the bridge: the adapter hands it the two closures.
final class DevToolsProtocolAutomation: EngineTabAutomation {
    typealias Execute = (_ method: String, _ paramsJSON: String?, _ completion: @escaping (Bool, String) -> Void) -> Void
    typealias SetEventHandler = (_ handler: ((String, String) -> Void)?) -> Void

    private let execute: Execute
    private let setEventHandler: SetEventHandler
    private var screencastFrameHandler: ((Data, TimeInterval) -> Void)?

    init(execute: @escaping Execute, setEventHandler: @escaping SetEventHandler) {
        self.execute = execute
        self.setEventHandler = setEventHandler
    }

    private func send(
        _ method: String,
        _ params: [String: Any]? = nil,
        completion: @escaping (Result<[String: Any], EngineAutomationError>) -> Void
    ) {
        var paramsJSON: String?
        if let params {
            guard let data = try? JSONSerialization.data(withJSONObject: params) else {
                return completion(.failure(EngineAutomationError("could not encode \(method) parameters")))
            }
            paramsJSON = String(decoding: data, as: UTF8.self)
        }
        execute(method, paramsJSON) { success, json in
            let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
            if success {
                completion(.success(object))
            } else {
                completion(.failure(EngineAutomationError(object["message"] as? String ?? "\(method) failed")))
            }
        }
    }

    private func sendVoid(_ method: String, _ params: [String: Any]? = nil, completion: @escaping (Result<Void, EngineAutomationError>) -> Void) {
        send(method, params) { completion($0.map { _ in () }) }
    }

    /// Runs `steps` in order, stopping at the first failure.
    private func sequence(_ steps: [(String, [String: Any])], completion: @escaping (Result<Void, EngineAutomationError>) -> Void) {
        guard let (method, params) = steps.first else { return completion(.success(())) }
        sendVoid(method, params) { [weak self] result in
            guard case .success = result, let self else { return completion(result) }
            self.sequence(Array(steps.dropFirst()), completion: completion)
        }
    }

    func setExactViewport(_ size: CGSize, completion: @escaping (Result<Void, EngineAutomationError>) -> Void) {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              size.width.rounded() == size.width, size.height.rounded() == size.height else {
            return completion(.failure(EngineAutomationError("exact viewport dimensions must be positive whole CSS pixels")))
        }
        sendVoid("Emulation.setDeviceMetricsOverride", [
            // Zero leaves dimensions sourced from the native host view.
            "width": 0, "height": 0, "deviceScaleFactor": 1, "mobile": false,
        ], completion: completion)
    }

    func prepare(completion: @escaping (Result<Void, EngineAutomationError>) -> Void) {
        sendVoid("Emulation.setFocusEmulationEnabled", ["enabled": true], completion: completion)
    }

    func evaluate(_ expression: String, completion: @escaping (Result<Any?, EngineAutomationError>) -> Void) {
        evaluate(expression, userGesture: true, completion: completion)
    }

    func measureViewport(completion: @escaping (Result<CGSize, EngineAutomationError>) -> Void) {
        evaluate("[window.innerWidth, window.innerHeight]", userGesture: false) { result in
            completion(result.flatMap(Self.viewportSize))
        }
    }

    private func evaluate(_ expression: String, userGesture: Bool, completion: @escaping (Result<Any?, EngineAutomationError>) -> Void) {
        send("Runtime.evaluate", [
            "expression": expression,
            "returnByValue": true,
            "awaitPromise": true,
            "userGesture": userGesture,
        ]) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let object):
                if let details = object["exceptionDetails"] as? [String: Any] {
                    let exception = details["exception"] as? [String: Any]
                    let message = exception?["description"] as? String ?? details["text"] as? String ?? "the script threw"
                    return completion(.failure(EngineAutomationError(message)))
                }
                let value = (object["result"] as? [String: Any])?["value"]
                completion(.success(value is NSNull ? nil : value))
            }
        }
    }

    func mouseMove(to point: CGPoint, completion: @escaping (Result<Void, EngineAutomationError>) -> Void) {
        sendVoid("Input.dispatchMouseEvent", ["type": "mouseMoved", "x": point.x, "y": point.y, "button": "none"], completion: completion)
    }

    func click(at point: CGPoint, clickCount: Int, completion: @escaping (Result<Void, EngineAutomationError>) -> Void) {
        var steps: [(String, [String: Any])] = [
            ("Input.dispatchMouseEvent", ["type": "mouseMoved", "x": point.x, "y": point.y, "button": "none"]),
        ]
        for count in 1...max(1, clickCount) {
            let base: [String: Any] = ["x": point.x, "y": point.y, "button": "left", "buttons": 1, "clickCount": count]
            steps.append(("Input.dispatchMouseEvent", base.merging(["type": "mousePressed"]) { $1 }))
            steps.append(("Input.dispatchMouseEvent", base.merging(["type": "mouseReleased", "buttons": 0]) { $1 }))
        }
        sequence(steps, completion: completion)
    }

    func scroll(at point: CGPoint, deltaX: Double, deltaY: Double, completion: @escaping (Result<Void, EngineAutomationError>) -> Void) {
        sendVoid("Input.dispatchMouseEvent", [
            "type": "mouseWheel", "x": point.x, "y": point.y, "deltaX": deltaX, "deltaY": deltaY,
        ], completion: completion)
    }

    func insertText(_ text: String, completion: @escaping (Result<Void, EngineAutomationError>) -> Void) {
        sendVoid("Input.insertText", ["text": text], completion: completion)
    }

    func pressKey(_ key: EngineAutomationKey, modifiers: EngineAutomationModifiers, completion: @escaping (Result<Void, EngineAutomationError>) -> Void) {
        var down: [String: Any] = [
            "type": key.text == nil || !modifiers.isDisjoint(with: [.command, .control]) ? "rawKeyDown" : "keyDown",
            "key": key.key, "code": key.code,
            "windowsVirtualKeyCode": key.keyCode, "nativeVirtualKeyCode": key.keyCode,
            "modifiers": modifiers.rawValue,
        ]
        if let text = key.text, modifiers.isDisjoint(with: [.command, .control]) {
            // What the chord types in the user's layout: Option+2 is "™".
            down["text"] = text.count == 1
                ? MacKeyboardLayout.typedText(for: text.first!, shift: modifiers.contains(.shift), option: modifiers.contains(.alt))
                : text
            down["unmodifiedText"] = text
        }
        var up = down
        up["type"] = "keyUp"
        up.removeValue(forKey: "text")
        up.removeValue(forKey: "unmodifiedText")
        sequence([("Input.dispatchKeyEvent", down), ("Input.dispatchKeyEvent", up)], completion: completion)
    }

    func screenshot(fullPage: Bool, completion: @escaping (Result<Data, EngineAutomationError>) -> Void) {
        let capture: ([String: Any]) -> Void = { [weak self] params in
            self?.send("Page.captureScreenshot", params) { result in
                switch result {
                case .failure(let error): completion(.failure(error))
                case .success(let object):
                    guard let base64 = object["data"] as? String, let data = Data(base64Encoded: base64) else {
                        return completion(.failure(EngineAutomationError("the engine returned no image")))
                    }
                    completion(.success(data))
                }
            }
        }
        guard fullPage else { return capture(["format": "png", "fromSurface": true]) }
        send("Page.getLayoutMetrics") { result in
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success(let metrics):
                let size = metrics["cssContentSize"] as? [String: Any] ?? metrics["contentSize"] as? [String: Any] ?? [:]
                let width = size["width"] as? Double ?? 0
                let height = size["height"] as? Double ?? 0
                guard width > 0, height > 0 else { return capture(["format": "png", "fromSurface": true]) }
                capture([
                    "format": "png", "fromSurface": true, "captureBeyondViewport": true,
                    "clip": ["x": 0, "y": 0, "width": width, "height": height, "scale": 1],
                ])
            }
        }
    }

    func startScreencast(
        quality: Int,
        onFrame: @escaping (Data, TimeInterval) -> Void,
        completion: @escaping (Result<Void, EngineAutomationError>) -> Void
    ) {
        screencastFrameHandler = onFrame
        setEventHandler { [weak self] method, paramsJSON in
            guard method == "Page.screencastFrame", let self else { return }
            guard let params = (try? JSONSerialization.jsonObject(with: Data(paramsJSON.utf8))) as? [String: Any] else { return }
            // The engine sends no further frame until this one is acked.
            if let sessionId = params["sessionId"] {
                self.sendVoid("Page.screencastFrameAck", ["sessionId": sessionId]) { _ in }
            }
            guard let base64 = params["data"] as? String, let data = Data(base64Encoded: base64) else { return }
            let timestamp = (params["metadata"] as? [String: Any])?["timestamp"] as? Double ?? Date().timeIntervalSince1970
            self.screencastFrameHandler?(data, timestamp)
        }
        // Without a size cap the frames come at full device resolution.
        sendVoid("Page.startScreencast", [
            "format": "jpeg", "quality": quality, "everyNthFrame": 1, "maxWidth": 8192, "maxHeight": 8192,
        ]) { [weak self] result in
            if case .failure = result { self?.stopScreencast() }
            completion(result)
        }
    }

    func stopScreencast() {
        screencastFrameHandler = nil
        setEventHandler(nil)
        sendVoid("Page.stopScreencast") { _ in }
    }
}
