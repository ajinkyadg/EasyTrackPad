import CMultitouchSupport
import CoreGraphics
import Foundation
import IOKit

/// Thin Swift wrapper around the private MultitouchSupport.framework C API
/// (see Sources/CMultitouchSupport). Delivers raw per-finger touch frames;
/// all gesture interpretation (finger counts, swipe direction, taps) lives
/// in `GestureRecognizer`, which is plain logic and testable without a
/// real trackpad.
///
/// Targets a specific physical device via `MTDeviceCreateFromService`,
/// fed an `io_service_t` found through the fully public IOKit APIs (see
/// `findService`) — not the private `MTDeviceCreateList()`/
/// `MTDeviceIsBuiltIn()` pair an earlier version of this file relied on.
/// That enumeration path never reliably delivered a single contact-frame
/// callback for a Magic Mouse on real hardware, regardless of how its
/// devices were selected. The fix, confirmed via `ioreg`: a Magic Mouse's
/// multitouch shell runs as its own `AppleMultitouchDevice`-class
/// IOService (Transport=Bluetooth, Product="Magic Mouse") — a real, live
/// kernel-driver instance, distinct from the trackpad's own
/// `AppleMultitouchDevice`. Enumerating those IOServices directly with
/// `IOServiceGetMatchingServices` and handing the right one to
/// `MTDeviceCreateFromService` delivers real touch frames for it, where
/// blind `MTDeviceCreateList()` enumeration never did.
public final class MultitouchGestureEngine {
    public struct Touch {
        public let id: Int32
        /// Normalized 0...1 position over the trackpad surface.
        public let position: CGPoint
        public let state: Int32

        public init(id: Int32, position: CGPoint, state: Int32) {
            self.id = id
            self.position = position
            self.state = state
        }
    }

    public struct Frame {
        public let touches: [Touch]
        public let timestamp: TimeInterval

        public init(touches: [Touch], timestamp: TimeInterval) {
            self.touches = touches
            self.timestamp = timestamp
        }
    }

    /// Which physical multitouch device to bind to — see `findService`.
    public enum DevicePreference {
        case builtIn
        case external
    }

    /// The C callback has no userInfo/refcon parameter, so it can't capture
    /// `self` — route frames back to the right engine via this registry,
    /// keyed by the callback's own `device` argument, instead. Two engines
    /// run concurrently in normal operation now (`TrackpadManager` runs one
    /// bound to the trackpad and one to a Magic Mouse simultaneously), so
    /// this can't be a single static slot — that was fine back when only
    /// one engine was ever alive at a time, but with two, the second
    /// `start()` would silently steal every callback meant for the first.
    fileprivate static var registry: [UnsafeMutableRawPointer: MultitouchGestureEngine] = [:]

    /// Called on whatever background thread MultitouchSupport delivers
    /// frames on (not main) — frames arrive at up to ~120Hz while
    /// touching, and hopping to main for every single one made the whole
    /// app (and perceptibly, the system) feel laggy. `GestureRecognizer`'s
    /// state is only ever touched from this callback, so staying off-main
    /// here is safe; callers must dispatch to main themselves before
    /// touching UI or posting synthetic events from `onGesture`.
    public var onFrame: ((Frame) -> Void)?

    private var device: MTDeviceRef?
    /// The IOService `device` was created from via `MTDeviceCreateFromService`
    /// — kept alive for as long as `device` is running, released alongside
    /// it in `stop()`. Zero when `device` came from `MTDeviceCreateDefault()`
    /// instead (the `.builtIn` no-match fallback), which owns its own
    /// service internally.
    private var matchedService: io_service_t = 0

    /// `true` only when the running device was matched as the Mac's own
    /// "MT Built-In" trackpad — not the `MTDeviceCreateDefault()` fallback,
    /// which on a desktop Mac is a Magic Trackpad of a different size.
    /// Anything measured in mm (corner clicks) must not assume the built-in
    /// pad's dimensions unless this is set.
    public private(set) var isBoundToBuiltIn = false

    public init() {}

    /// Returns whether a multitouch device was actually found and started —
    /// `false` means either no matching physical device is connected, or
    /// the private MultitouchSupport.framework has changed or disappeared
    /// on this macOS version (an accepted, real risk of depending on it;
    /// see README). Callers use this to degrade gracefully: finger-count
    /// swipe/tap detection needs this, but pinch/rotate (public `NSEvent`
    /// monitors) and keyboard/mouse remapping (public `CGEventTap`) don't
    /// depend on this at all and keep working regardless.
    @discardableResult
    public func start(preferring preference: DevicePreference = .builtIn) -> Bool {
        if let service = Self.findService(preferring: preference) {
            guard let device = MTDeviceCreateFromService(service) else {
                NSLog("InputCustomizer: MTDeviceCreateFromService failed for a matched \(preference) IOService — falling back")
                IOObjectRelease(service)
                return startFallback(for: preference)
            }
            matchedService = service
            isBoundToBuiltIn = preference == .builtIn
            return start(withDevice: device)
        }
        return startFallback(for: preference)
    }

    /// `.builtIn` unconditionally falls back to `MTDeviceCreateDefault()`
    /// when no `AppleMultitouchDevice` IOService is marked "MT Built-In" —
    /// NOT gated on the enumeration coming back empty, since a user with
    /// no Magic Mouse (the common case) must never lose gesture detection
    /// entirely just because this property-based classification behaves
    /// unexpectedly on some macOS version. `.external` has no such
    /// fallback: `MTDeviceCreateDefault()` could silently hand back the
    /// trackpad's device, masking "no Magic Mouse connected" as if it
    /// worked.
    private func startFallback(for preference: DevicePreference) -> Bool {
        guard preference == .builtIn else {
            NSLog("InputCustomizer: no external (non-built-in) multitouch device found")
            return false
        }
        guard let device = MTDeviceCreateDefault() else {
            NSLog("InputCustomizer: MTDeviceCreateDefault() returned nil — no multitouch device found, or MultitouchSupport.framework is unavailable on this macOS version. Trackpad swipe/tap gestures will not fire; pinch, rotate, mouse, and keyboard rules are unaffected.")
            return false
        }
        return start(withDevice: device)
    }

    private func start(withDevice device: MTDeviceRef) -> Bool {
        NSLog("InputCustomizer: multitouch device created, starting callback registration")
        self.device = device
        MultitouchGestureEngine.registry[device] = self

        MTRegisterContactFrameCallback(device) { deviceRef, touchesPtr, numTouches, timestamp, _ in
            guard let deviceRef, let engine = MultitouchGestureEngine.registry[deviceRef], let touchesPtr else { return 0 }
            var touches: [Touch] = []
            touches.reserveCapacity(Int(numTouches))
            for i in 0..<Int(numTouches) {
                let raw = touchesPtr[i]
                touches.append(Touch(
                    id: raw.identifier,
                    position: CGPoint(x: CGFloat(raw.normalizedVector.position.x), y: CGFloat(raw.normalizedVector.position.y)),
                    state: raw.state
                ))
            }
            let frame = Frame(touches: touches, timestamp: timestamp)
            engine.onFrame?(frame)
            return 0
        }
        MTDeviceStart(device, 0)
        NSLog("InputCustomizer: MTDeviceStart called")
        return true
    }

    public func stop() {
        guard let device else { return }
        // Not calling MTUnregisterContactFrameCallback: our callback is a
        // capture-less closure, so there's no stored function pointer value
        // to pass back, and passing the wrong one risks undefined behavior
        // in this undocumented API. Stopping + releasing the device is
        // sufficient to halt delivery.
        MTDeviceStop(device)
        MTDeviceRelease(device)
        MultitouchGestureEngine.registry[device] = nil
        self.device = nil
        isBoundToBuiltIn = false
        if matchedService != 0 {
            IOObjectRelease(matchedService)
            matchedService = 0
        }
    }

    deinit {
        stop()
    }

    /// Finds the `AppleMultitouchDevice`-class IOService for the physical
    /// device matching `preference`, using only fully public IOKit APIs.
    /// Classifies built-in vs. external via the "MT Built-In" IORegistry
    /// property IOKit itself already publishes on each instance (confirmed
    /// via `ioreg`: `Yes` on the trackpad's entry, absent on a Magic
    /// Mouse's) — not the private `MTDeviceIsBuiltIn()` function call,
    /// which required an already-created `MTDeviceRef` from the
    /// unreliable enumeration path this replaces. Returns an owned
    /// reference the caller must eventually `IOObjectRelease` (done in
    /// `stop()` once handed to `MTDeviceCreateFromService`).
    private static func findService(preferring preference: DevicePreference) -> io_service_t? {
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleMultitouchDevice"), &iterator)
        guard result == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            let matchesPreference = isBuiltIn(service) == (preference == .builtIn)
            if matchesPreference { return service }
            IOObjectRelease(service)
        }
        return nil
    }

    private static func isBuiltIn(_ service: io_service_t) -> Bool {
        guard let cf = IORegistryEntryCreateCFProperty(service, "MT Built-In" as CFString, kCFAllocatorDefault, 0) else { return false }
        let value = cf.takeRetainedValue()
        guard CFGetTypeID(value) == CFBooleanGetTypeID() else { return false }
        return CFBooleanGetValue((value as! CFBoolean))
    }
}
