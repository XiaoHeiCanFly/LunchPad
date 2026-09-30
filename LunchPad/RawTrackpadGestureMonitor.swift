import AppKit
import Darwin

private typealias MTDeviceRef = UnsafeMutableRawPointer
private typealias MTContactCallback = @convention(c) (
    MTDeviceRef?, UnsafeRawPointer?, Int32, Double, Int32
) -> Void
private typealias MTDeviceCreateDefaultFunction = @convention(c) () -> MTDeviceRef?
private typealias MTDeviceCreateListFunction = @convention(c) () -> CFArray?
private typealias MTRegisterContactFrameCallbackFunction = @convention(c) (MTDeviceRef?, MTContactCallback) -> Void
private typealias MTDeviceStartFunction = @convention(c) (MTDeviceRef?, Int32) -> Void
private typealias MTDeviceStopFunction = @convention(c) (MTDeviceRef?) -> Void

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

    /// True while a four-finger attempt was seen recently — including the
    /// window after a failed attempt where fingers are still on the pad. The
    /// CGEvent tap must keep swallowing system gestures there, or the system
    /// fires its own action for the same contact.
    var isSuppressing: Bool {
        lock.lock(); defer { lock.unlock() }
        return Date() < suppressUntil
    }

    var hasFourFingerContact: Bool {
        TrackpadContactState.shared.contactActive
    }
}

/// Pins the contact state machine to the trackpad that produced the
/// qualifying frames. A second device's empty frames must never interleave:
/// they would end the first device's gesture through the grace path.
private nonisolated final class ContactDeviceOwnership: @unchecked Sendable {
    static let shared = ContactDeviceOwnership()

    private let lock = NSLock()
    private var owner: MTDeviceRef?

    func isEligible(_ device: MTDeviceRef) -> Bool {
        // Ownership only matters while a contact or candidate is live. A stale
        // owner (expiry observed by a display frame instead of a touch frame)
        // must never lock out the other trackpad permanently.
        guard TrackpadContactState.shared.hasPendingState else {
            lock.lock(); owner = nil; lock.unlock()
            return true
        }
        lock.lock(); defer { lock.unlock() }
        return owner == nil || owner == device
    }

    func claim(_ device: MTDeviceRef) {
        lock.lock(); defer { lock.unlock() }
        if owner == nil { owner = device }
    }

    func releaseIfIdle() {
        guard !TrackpadContactState.shared.hasPendingState else { return }
        lock.lock(); owner = nil; lock.unlock()
    }
}

/// Aggregated per-sequence telemetry for the raw contact callback. Lines are
/// written only at sequence boundaries — never per frame — so the callback
/// stays allocation- and I/O-light. Everything here is lock-protected; the
/// terminal path runs under the contact state's lock, so keep the handler a
/// single line.
nonisolated final class GestureTouchDiagnostics: @unchecked Sendable {
    static let shared = GestureTouchDiagnostics()

    private let lock = NSLock()
    private var armedSince: TimeInterval?
    private var frames = 0
    private var qualifiedFrames = 0
    private var otherDeviceDrops = 0
    private var rawHistogram: [Int: Int] = [:]
    private var clusterHistogram: [Int: Int] = [:]
    private var lastCoordLogAt: TimeInterval = 0
    private var lastTapLogAt: TimeInterval = 0

    /// Records one processed frame. Counters only arm once a qualifying
    /// (four-cluster) frame appears, so ordinary one-finger use never accumulates.
    func noteFrame(raw: Int, clusters: Int, qualified: Bool) {
        lock.lock(); defer { lock.unlock() }
        if armedSince == nil {
            guard qualified else { return }
            armedSince = ProcessInfo.processInfo.systemUptime
        }
        frames += 1
        if qualified { qualifiedFrames += 1 }
        rawHistogram[raw, default: 0] += 1
        clusterHistogram[clusters, default: 0] += 1
    }

    func noteOtherDeviceDrop() {
        lock.lock(); defer { lock.unlock() }
        guard armedSince != nil else { return }
        otherDeviceDrops += 1
    }

    func noteTerminal(_ event: TrackpadContactState.TerminalEvent) {
        lock.lock(); defer { lock.unlock() }
        guard let since = armedSince else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let line = "end=\(event.outcome.rawValue)"
            + " gen=\(event.generation)"
            + " dur=\(fixed(now - since))"
            + " motion=\(fixed(event.motion))"
            + " frames=\(frames) qualified=\(qualifiedFrames)"
            + " raw=\(histogramText(rawHistogram))"
            + " clusters=\(histogramText(clusterHistogram))"
            + " other-drops=\(otherDeviceDrops)"
        armedSince = nil
        frames = 0
        qualifiedFrames = 0
        otherDeviceDrops = 0
        rawHistogram = [:]
        clusterHistogram = [:]
        LauncherDiagnostics.shared.record("gesture-touch", line)
    }

    /// Rate-limited: a broken contact layout would otherwise log every frame.
    func noteCoordViolation(x: CGFloat, y: CGFloat, index: Int) {
        lock.lock(); defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastCoordLogAt >= 60 else { return }
        lastCoordLogAt = now
        LauncherDiagnostics.shared.record(
            "gesture-touch",
            "coords-out-of-range index=\(index) x=\(x) y=\(y) — private contact layout may have changed"
        )
    }

    /// Audit line for system begin/end gesture events (rate-limited to 1/s).
    func noteSystemGesture(_ kind: String, _ flags: String) {
        lock.lock(); defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastTapLogAt >= 1 else { return }
        lastTapLogAt = now
        LauncherDiagnostics.shared.record("gesture-tap", "sys-gesture \(kind) \(flags)")
    }

    private func fixed(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private func histogramText(_ histogram: [Int: Int]) -> String {
        let parts = histogram.keys.sorted().map { "\($0):\(histogram[$0] ?? 0)" }
        return "{\(parts.joined(separator: ","))}"
    }
}

/// Contacts are read as raw points and clustered first: a rolling finger
/// split into two reports, or a fifth contact at the pad edge, must not flip
/// the effective finger count.
private nonisolated let maximumTrackedContacts = 10

nonisolated private func lunchPadTrackpadContactCallback(
    _ device: MTDeviceRef?,
    _ contacts: UnsafeRawPointer?,
    _ contactCount: Int32,
    _ timestamp: Double,
    _ frame: Int32
) {
    let now = ProcessInfo.processInfo.systemUptime
    let gate = TrackpadSystemGestureGate.shared

    // A second trackpad's frames must not interleave with the device that
    // owns the in-flight contact or candidate.
    if let device, !ContactDeviceOwnership.shared.isEligible(device) {
        GestureTouchDiagnostics.shared.noteOtherDeviceDrop()
        return
    }

    let rawCount = Int(contactCount)
    guard let contacts, rawCount > 0 else {
        GestureTouchDiagnostics.shared.noteFrame(raw: rawCount, clusters: 0, qualified: false)
        TrackpadContactState.shared.endContact(contactCount: 0, at: now)
        ContactDeviceOwnership.shared.releaseIfIdle()
        return
    }

    var points: [CGPoint] = []
    points.reserveCapacity(min(rawCount, maximumTrackedContacts))
    for index in 0..<min(rawCount, maximumTrackedContacts) {
        let record = contacts.advanced(by: index * 96)
        let x = CGFloat(record.load(fromByteOffset: 32, as: Float.self))
        let y = CGFloat(record.load(fromByteOffset: 36, as: Float.self))
        // Out-of-range coordinates usually mean the private contact layout
        // changed with an OS update; skip the frame and say so (rate-limited).
        guard x.isFinite, y.isFinite,
              x >= -0.15, x <= 1.15, y >= -0.15, y <= 1.15 else {
            GestureTouchDiagnostics.shared.noteCoordViolation(x: x, y: y, index: index)
            if rawCount >= 4 { gate.suppress(for: 0.6) }
            return
        }
        points.append(CGPoint(x: x, y: y))
    }

    let centers = TrackpadContactClustering.centers(of: points)
    GestureTouchDiagnostics.shared.noteFrame(
        raw: rawCount, clusters: centers.count, qualified: centers.count == 4
    )

    guard centers.count == 4 else {
        // Four or more *distinct* fingers are an attempt at our gesture — keep
        // the system's own gesture events out until the contact settles.
        // Three distinct fingers (even if raw count was inflated by a split)
        // belong to the system and must not be suppressed.
        if centers.count >= 4 { gate.suppress(for: 0.6) }
        TrackpadContactState.shared.endContact(contactCount: centers.count, at: now)
        ContactDeviceOwnership.shared.releaseIfIdle()
        return
    }

    if let device { ContactDeviceOwnership.shared.claim(device) }
    gate.pendingBeginGesture = false
    gate.suppress(for: 0.6)

    var cx: CGFloat = 0, cy: CGFloat = 0
    for center in centers {
        cx += center.x; cy += center.y
    }
    cx /= 4; cy /= 4

    var radius: CGFloat = 0
    for center in centers {
        radius += hypot(center.x - cx, center.y - cy)
    }
    radius /= 4

    // Wake the main-thread animator once per contact sequence. This is a
    // single hop per gesture — never per frame. The generation prevents a
    // delayed wakeup from attaching itself to a later set of fingers.
    if let generation = TrackpadContactState.shared.noteQualifiedFrame(radius: radius, at: now) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                LauncherController.shared.rawTrackpadGestureBegan(generation: generation)
            }
        }
    }
    ContactDeviceOwnership.shared.releaseIfIdle()
}

@MainActor
final class RawTrackpadGestureMonitor {
    static let shared = RawTrackpadGestureMonitor()

    private(set) var isRunning = false

    private var frameworkHandle: UnsafeMutableRawPointer?
    private var createDefaultFunction: MTDeviceCreateDefaultFunction?
    private var createListFunction: MTDeviceCreateListFunction?
    private var registerFunction: MTRegisterContactFrameCallbackFunction?
    private var startFunction: MTDeviceStartFunction?
    private var stopFunction: MTDeviceStopFunction?
    private var registeredDevices: Set<MTDeviceRef> = []
    private var trackedDevices: [MTDeviceRef] = []
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    private init() {}

    func start() {
        guard !isRunning else { return }
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let frameworkHandle = dlopen(path, RTLD_NOW | RTLD_LOCAL),
              let registerSymbol = dlsym(frameworkHandle, "MTRegisterContactFrameCallback"),
              let startSymbol = dlsym(frameworkHandle, "MTDeviceStart") else {
            return
        }
        let createDefaultSymbol = dlsym(frameworkHandle, "MTDeviceCreateDefault")
        let createListSymbol = dlsym(frameworkHandle, "MTDeviceCreateList")
        guard createDefaultSymbol != nil || createListSymbol != nil else { return }

        self.frameworkHandle = frameworkHandle
        registerFunction = unsafeBitCast(registerSymbol, to: MTRegisterContactFrameCallbackFunction.self)
        startFunction = unsafeBitCast(startSymbol, to: MTDeviceStartFunction.self)
        if let stopSymbol = dlsym(frameworkHandle, "MTDeviceStop") {
            stopFunction = unsafeBitCast(stopSymbol, to: MTDeviceStopFunction.self)
        }
        if let createListSymbol {
            createListFunction = unsafeBitCast(createListSymbol, to: MTDeviceCreateListFunction.self)
        }
        if let createDefaultSymbol {
            createDefaultFunction = unsafeBitCast(createDefaultSymbol, to: MTDeviceCreateDefaultFunction.self)
        }

        TrackpadContactState.shared.setTerminalEventHandler { event in
            GestureTouchDiagnostics.shared.noteTerminal(event)
        }
        refreshDevices(reason: "start", restart: false)
        isRunning = true
        let center = NSWorkspace.shared.notificationCenter
        sleepObserver = center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                RawTrackpadGestureMonitor.shared.handleSleep()
            }
        }
        wakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                RawTrackpadGestureMonitor.shared.handleWake()
            }
        }
    }

    /// Sleep stops every known device (the framework drops delivery across
    /// sleep), and wake re-registers hot-plugged trackpads before restarting —
    /// gestures must survive both without an app relaunch.
    private func handleSleep() {
        for device in trackedDevices { stopFunction?(device) }
        TrackpadContactState.shared.cancelContact()
        LauncherController.shared.cancelTrackpadGesture()
    }

    private func handleWake() {
        refreshDevices(reason: "wake", restart: true)
    }

    private func refreshDevices(reason: String, restart: Bool) {
        var devices: [MTDeviceRef] = []
        if let createList = createListFunction, let list = createList() {
            // Deliberately not released: device pointers extracted from the
            // array must outlive it, and one small array per wake is nothing.
            let count = CFArrayGetCount(list)
            for index in 0..<count {
                guard let element = CFArrayGetValueAtIndex(list, index) else { continue }
                devices.append(UnsafeMutableRawPointer(mutating: element))
            }
        } else if let createDefault = createDefaultFunction, let device = createDefault() {
            devices.append(device)
        }

        var newCount = 0
        if let register = registerFunction {
            for device in devices where !registeredDevices.contains(device) {
                register(device, lunchPadTrackpadContactCallback)
                registeredDevices.insert(device)
                newCount += 1
            }
        }
        if restart { for device in devices { stopFunction?(device) } }
        for device in devices { startFunction?(device, 0) }
        trackedDevices = devices
        LauncherDiagnostics.shared.record(
            "gesture-touch",
            "devices reason=\(reason) count=\(devices.count) new=\(newCount) restart=\(restart)"
        )
    }

    nonisolated static var hasFourFingerContact: Bool {
        TrackpadSystemGestureGate.shared.hasFourFingerContact
    }

    /// Recent four-finger activity (including failed attempts) still owns the
    /// system's gesture events for the suppression window.
    nonisolated static var isSystemGestureSuppressed: Bool {
        TrackpadSystemGestureGate.shared.isSuppressing
    }

    nonisolated static var pendingBeginGesture: Bool {
        get { TrackpadSystemGestureGate.shared.pendingBeginGesture }
        set { TrackpadSystemGestureGate.shared.pendingBeginGesture = newValue }
    }
}
