import CoreLocation
import Darwin
import WebKit

/// Feeds CoreLocation positions to WebKit's geolocation service.
///
/// On macOS, `WKWebView` has no position source of its own. Granting a page's
/// geolocation request (`WebKitTab+UIDelegate`) only lets the request through:
/// WebKit then asks the process pool's geolocation provider to start
/// updating, and with no provider registered, nothing ever answers. The page's
/// `getCurrentPosition` then waits forever. Safari registers its own provider
/// the same way, through WebKit's C API (`WKGeolocationManagerSetProvider`).
///
/// None of those C functions are in a public header, so each one is looked up
/// with `dlsym` at run time and nothing private is linked. If any is missing,
/// `install(on:)` does nothing and pages behave as before.
///
/// A WebKit C API ref (`WKContextRef`) is the same pointer as its Objective-C
/// wrapper (`WKProcessPool`), which is how the pool is passed to the C API.
final class WebKitGeolocation: NSObject, CLLocationManagerDelegate {
    static let shared = WebKitGeolocation()

    private typealias ContextGetGeolocationManager = @convention(c) (UnsafeRawPointer) -> UnsafeRawPointer?
    private typealias SetProvider = @convention(c) (UnsafeRawPointer, UnsafeRawPointer) -> Void
    private typealias PositionCreate = @convention(c) (Double, Double, Double, Double) -> UnsafeRawPointer?
    private typealias DidChangePosition = @convention(c) (UnsafeRawPointer, UnsafeRawPointer) -> Void
    private typealias DidFail = @convention(c) (UnsafeRawPointer) -> Void
    private typealias Release = @convention(c) (UnsafeRawPointer) -> Void

    private typealias StartStop = @convention(c) (UnsafeRawPointer?, UnsafeRawPointer?) -> Void
    private typealias SetHighAccuracy = @convention(c) (UnsafeRawPointer?, Bool, UnsafeRawPointer?) -> Void

    private struct SPI {
        let contextGetGeolocationManager: ContextGetGeolocationManager
        let setProvider: SetProvider
        let positionCreate: PositionCreate
        let didChangePosition: DidChangePosition
        let didFail: DidFail
        let release: Release

        static let shared: SPI? = {
            func symbol<T>(_ name: String, as type: T.Type) -> T? {
                guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil } // RTLD_DEFAULT
                return unsafeBitCast(pointer, to: type)
            }
            guard let getManager = symbol("WKContextGetGeolocationManager", as: ContextGetGeolocationManager.self),
                  let setProvider = symbol("WKGeolocationManagerSetProvider", as: SetProvider.self),
                  let positionCreate = symbol("WKGeolocationPositionCreate", as: PositionCreate.self),
                  let didChange = symbol("WKGeolocationManagerProviderDidChangePosition", as: DidChangePosition.self),
                  let didFail = symbol("WKGeolocationManagerProviderDidFailToDeterminePosition", as: DidFail.self),
                  let release = symbol("WKRelease", as: Release.self)
            else { return nil }
            return SPI(contextGetGeolocationManager: getManager, setProvider: setProvider, positionCreate: positionCreate,
                       didChangePosition: didChange, didFail: didFail, release: release)
        }()
    }

    /// `WKGeolocationProviderV1`: `{ int version; const void *clientInfo; }`
    /// followed by the startUpdating, stopUpdating and setEnableHighAccuracy
    /// callbacks. Built at fixed C offsets rather than as a Swift struct,
    /// whose layout Swift does not promise. WebKit copies it, but it is kept
    /// for the life of the app anyway.
    private static let providerV1: UnsafeMutableRawPointer = {
        let pointerSize = MemoryLayout<UnsafeRawPointer>.size
        let memory = UnsafeMutableRawPointer.allocate(byteCount: pointerSize * 5, alignment: MemoryLayout<UnsafeRawPointer>.alignment)
        memory.initializeMemory(as: UInt8.self, repeating: 0, count: pointerSize * 5)
        memory.storeBytes(of: Int32(1), as: Int32.self)
        let start: StartStop = { manager, _ in
            guard let manager else { return }
            WebKitGeolocation.shared.startUpdating(manager: manager)
        }
        let stop: StartStop = { manager, _ in
            guard let manager else { return }
            WebKitGeolocation.shared.stopUpdating(manager: manager)
        }
        let highAccuracy: SetHighAccuracy = { manager, enabled, _ in
            guard let manager else { return }
            WebKitGeolocation.shared.setHighAccuracy(enabled, manager: manager)
        }
        memory.storeBytes(of: start, toByteOffset: pointerSize * 2, as: StartStop.self)
        memory.storeBytes(of: stop, toByteOffset: pointerSize * 3, as: StartStop.self)
        memory.storeBytes(of: highAccuracy, toByteOffset: pointerSize * 4, as: SetHighAccuracy.self)
        return memory
    }()

    private let locationManager = CLLocationManager()
    private var installedPools = Set<ObjectIdentifier>()
    /// Geolocation managers (one per process pool) that currently want positions.
    private var updatingManagers: [UnsafeRawPointer] = []
    private var highAccuracyManagers = Set<UnsafeRawPointer>()

    private override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// Registers the provider on `processPool` once. Must run before the
    /// page's request is granted, because WebKit starts updating right after.
    func install(on processPool: WKProcessPool) {
        guard let spi = SPI.shared, installedPools.insert(ObjectIdentifier(processPool)).inserted else { return }
        let context = UnsafeRawPointer(Unmanaged.passUnretained(processPool).toOpaque())
        guard let manager = spi.contextGetGeolocationManager(context) else { return }
        spi.setProvider(manager, Self.providerV1)
    }

    private func startUpdating(manager: UnsafeRawPointer) {
        if !updatingManagers.contains(manager) { updatingManagers.append(manager) }
        switch locationManager.authorizationStatus {
        case .notDetermined:
            // locationManagerDidChangeAuthorization starts updates once the user answers.
            locationManager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            failAll()
        default:
            locationManager.startUpdatingLocation()
            if let last = locationManager.location { send(last) }
        }
    }

    private func stopUpdating(manager: UnsafeRawPointer) {
        updatingManagers.removeAll { $0 == manager }
        highAccuracyManagers.remove(manager)
        applyAccuracy()
        if updatingManagers.isEmpty { locationManager.stopUpdatingLocation() }
    }

    private func setHighAccuracy(_ enabled: Bool, manager: UnsafeRawPointer) {
        if enabled { highAccuracyManagers.insert(manager) } else { highAccuracyManagers.remove(manager) }
        applyAccuracy()
    }

    private func applyAccuracy() {
        locationManager.desiredAccuracy = highAccuracyManagers.isEmpty ? kCLLocationAccuracyHundredMeters : kCLLocationAccuracyBest
    }

    private func send(_ location: CLLocation) {
        guard let spi = SPI.shared else { return }
        for manager in updatingManagers {
            guard let position = spi.positionCreate(location.timestamp.timeIntervalSince1970,
                                                    location.coordinate.latitude,
                                                    location.coordinate.longitude,
                                                    location.horizontalAccuracy) else { continue }
            spi.didChangePosition(manager, position)
            spi.release(position)
        }
    }

    private func failAll() {
        guard let spi = SPI.shared else { return }
        for manager in updatingManagers { spi.didFail(manager) }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard !updatingManagers.isEmpty else { return }
        switch manager.authorizationStatus {
        case .notDetermined:
            return
        case .denied, .restricted:
            failAll()
        default:
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let last = locations.last { send(last) }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // kCLErrorLocationUnknown is temporary: CoreLocation keeps trying.
        if (error as? CLError)?.code == .locationUnknown { return }
        failAll()
    }
}
