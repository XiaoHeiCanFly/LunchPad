import AppKit
import Darwin

private typealias MTDeviceRef = UnsafeMutableRawPointer
private typealias MTContactCallback = @convention(c) (
    MTDeviceRef?, UnsafeRawPointer?, Int32, Double, Int32
) -> Void
private typealias MTDeviceCreateDefaultFunction = @convention(c) () -> MTDeviceRef?
private typealias MTRegisterContactFrameCallbackFunction = @convention(c) (MTDeviceRef?, MTContactCallback) -> Void
private typealias MTDeviceStartFunction = @convention(c) (MTDeviceRef?, Int32) -> Void

/// Thread-safe gesture contact state written by the raw-trackpad callback
/// thread and read by the main-thread display-link animator.
///
/// There are no main-thread hops for data: the callback only writes these
/// locked values and the animator samples them every display frame, so frame
/// delivery stays synchronized to VSYNC.
nonisolated final class TrackpadContactState: @unchecked Sendable {
    static let shared = TrackpadContactState()

    private let lock = NSLock()
    private var startRadius: CGFloat?
    private var latestRadius: CGFloat = 0
    private var contactIsActive = false
    private var needsWakeup = false
    private var lastFourFingerFrameUptime: TimeInterval = 0

    /// MultitouchSupport briefly reports 3/5 contacts while four fingers are
    /// landing or lifting. Ending on the first such frame makes a valid pinch
    /// close again within one display tick. Preserve the contact across a few
    /// sensor frames, while keeping release latency below a tenth of a second.
    private static let contactLossGrace: TimeInterval = 0.075

    /// Total radius change since the contact began (startRadius − latest).
    /// Positive = fingers moving together, negative = spreading.
    var motion: CGFloat {
        lock.lock(); defer { lock.unlock() }
        guard let startRadius else { return 0 }
        return startRadius - latestRadius
    }

    var contactActive: Bool {
        lock.lock(); defer { lock.unlock() }
        expireContactIfNeededLocked(now: ProcessInfo.processInfo.systemUptime)
        return contactIsActive
    }

    /// Whether a new four-finger contact began since the last consume. Used to
    /// dispatch a single main-thread wakeup per gesture; the display link then
    /// takes over per-frame sampling.
    func consumeNeedsWakeup() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let value = needsWakeup
        needsWakeup = false
        return value
    }

    func updateContact(radius: CGFloat) {
        lock.lock()
        let now = ProcessInfo.processInfo.systemUptime
        expireContactIfNeededLocked(now: now)
        if !contactIsActive {
            // Transition into a new contact: record the baseline.
            contactIsActive = true
            startRadius = radius
            latestRadius = radius
            needsWakeup = true
        } else {
            latestRadius = radius
        }
        lastFourFingerFrameUptime = now
        lock.unlock()
    }

    func endContact() {
        lock.lock()
        // Do not tear down on a single noisy non-four-finger frame. Repeated
        // frames, or the animator's next contactActive poll, expire it after
        // the short grace period above.
        expireContactIfNeededLocked(now: ProcessInfo.processInfo.systemUptime)
        lock.unlock()
    }

    private func expireContactIfNeededLocked(now: TimeInterval) {
        guard contactIsActive,
              now - lastFourFingerFrameUptime > Self.contactLossGrace else { return }
        contactIsActive = false
        startRadius = nil
        latestRadius = 0
    }
}

/// Tracks system-gesture suppression and four-finger contact so the CGEvent
/// tap can block Mission Control / spaces while a pinch is in progress.
private nonisolated final class TrackpadSystemGestureGate: @unchecked Sendable {
    static let shared = TrackpadSystemGestureGate()

    private let lock = NSLock()
    private var suppressUntil = Date.distantPast
    private var _pendingBeginGesture = false

    var pendingBeginGesture: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _pendingBeginGesture }
        set { lock.lock(); _pendingBeginGesture = newValue; lock.unlock() }
    }

    func suppress(for duration: TimeInterval) {
        lock.lock()
        suppressUntil = max(suppressUntil, Date().addingTimeInterval(duration))
        lock.unlock()
    }

    var hasFourFingerContact: Bool {
        TrackpadContactState.shared.contactActive
    }
}

nonisolated private func lunchPadTrackpadContactCallback(
    _ device: MTDeviceRef?,
    _ contacts: UnsafeRawPointer?,
    _ contactCount: Int32,
    _ timestamp: Double,
    _ frame: Int32
) {
    guard let contacts, contactCount == 4 else {
        TrackpadSystemGestureGate.shared.suppress(for: 0.6)
        TrackpadContactState.shared.endContact()
        return
    }

    let gate = TrackpadSystemGestureGate.shared
    gate.pendingBeginGesture = false
    gate.suppress(for: 0.6)

    let recordStride = 96
    var cx: CGFloat = 0, cy: CGFloat = 0
    for index in 0..<4 {
        let record = contacts.advanced(by: index * recordStride)
        let x = CGFloat(record.load(fromByteOffset: 32, as: Float.self))
        let y = CGFloat(record.load(fromByteOffset: 36, as: Float.self))
        guard x.isFinite, y.isFinite else { return }
        cx += x; cy += y
    }
    cx /= 4; cy /= 4

    var radius: CGFloat = 0
    for index in 0..<4 {
        let record = contacts.advanced(by: index * recordStride)
        let x = CGFloat(record.load(fromByteOffset: 32, as: Float.self))
        let y = CGFloat(record.load(fromByteOffset: 36, as: Float.self))
        radius += hypot(x - cx, y - cy)
    }
    radius /= 4

    TrackpadContactState.shared.updateContact(radius: radius)

    // Wake the main-thread animator once per contact sequence. This is a
    // single hop per gesture — never per frame.
    if TrackpadContactState.shared.consumeNeedsWakeup() {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                LauncherController.shared.rawTrackpadGestureBegan()
            }
        }
    }
}

@MainActor
final class RawTrackpadGestureMonitor {
    static let shared = RawTrackpadGestureMonitor()

    private(set) var isRunning = false

    private var frameworkHandle: UnsafeMutableRawPointer?
    private var device: MTDeviceRef?

    private init() {}

    func start() {
        guard !isRunning else { return }
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let frameworkHandle = dlopen(path, RTLD_NOW | RTLD_LOCAL),
              let createSymbol = dlsym(frameworkHandle, "MTDeviceCreateDefault"),
              let registerSymbol = dlsym(frameworkHandle, "MTRegisterContactFrameCallback"),
              let startSymbol = dlsym(frameworkHandle, "MTDeviceStart") else {
            return
        }

        let createDevice = unsafeBitCast(createSymbol, to: MTDeviceCreateDefaultFunction.self)
        let registerCallback = unsafeBitCast(registerSymbol, to: MTRegisterContactFrameCallbackFunction.self)
        let startDevice = unsafeBitCast(startSymbol, to: MTDeviceStartFunction.self)
        guard let device = createDevice() else { return }

        self.frameworkHandle = frameworkHandle
        self.device = device
        registerCallback(device, lunchPadTrackpadContactCallback)
        startDevice(device, 0)
        isRunning = true
    }

    nonisolated static var hasFourFingerContact: Bool {
        TrackpadSystemGestureGate.shared.hasFourFingerContact
    }

    nonisolated static var pendingBeginGesture: Bool {
        get { TrackpadSystemGestureGate.shared.pendingBeginGesture }
        set { TrackpadSystemGestureGate.shared.pendingBeginGesture = newValue }
    }
}
