import AppKit
import Darwin

private typealias MTDeviceRef = UnsafeMutableRawPointer
private typealias MTContactCallback = @convention(c) (
    MTDeviceRef?, UnsafeRawPointer?, Int32, Double, Int32
) -> Void
private typealias MTDeviceCreateDefaultFunction = @convention(c) () -> MTDeviceRef?
private typealias MTRegisterContactFrameCallbackFunction = @convention(c) (MTDeviceRef?, MTContactCallback) -> Void
private typealias MTDeviceStartFunction = @convention(c) (MTDeviceRef?, Int32) -> Void

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
    let now = ProcessInfo.processInfo.systemUptime
    guard let contacts, contactCount == 4 else {
        TrackpadSystemGestureGate.shared.suppress(for: 0.6)
        TrackpadContactState.shared.endContact(contactCount: Int(contactCount), at: now)
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

    // Wake the main-thread animator once per contact sequence. This is a
    // single hop per gesture — never per frame. The generation prevents a
    // delayed wakeup from attaching itself to a later set of fingers.
    if let generation = TrackpadContactState.shared.updateContact(radius: radius, at: now) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                LauncherController.shared.rawTrackpadGestureBegan(generation: generation)
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
    private var sleepObserver: NSObjectProtocol?

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
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                TrackpadContactState.shared.cancelContact()
                LauncherController.shared.cancelTrackpadGesture()
            }
        }
    }

    nonisolated static var hasFourFingerContact: Bool {
        TrackpadSystemGestureGate.shared.hasFourFingerContact
    }

    nonisolated static var pendingBeginGesture: Bool {
        get { TrackpadSystemGestureGate.shared.pendingBeginGesture }
        set { TrackpadSystemGestureGate.shared.pendingBeginGesture = newValue }
    }
}
