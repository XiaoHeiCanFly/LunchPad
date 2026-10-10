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

/// Show Desktop (entered by the system's four-finger spread) outranks our
/// pinch. After a deliberate spread, if the next four-contact sequence starts
/// with zero normal windows on screen — the signature of Show Desktop — the
/// sequence yields: no animator dispatch, no event swallowing, so the
/// system's own pinch dismisses the desktop first. Seeing any window again
/// clears the armed state.
private nonisolated final class DesktopYieldGate: @unchecked Sendable {
    static let shared = DesktopYieldGate()
    /// Net radius change that marks a deliberate spread (about half the
    /// animator's full-open sensitivity — well past jitter).
    static let spreadMotion: CGFloat = 0.01

    private let lock = NSLock()
    private var spreadSeen = false
    private var yieldsForSequence = false

    func noteDeliberateSpread() {
        lock.lock(); defer { lock.unlock() }
        spreadSeen = true
    }

    /// Called once per sequence, on the arming frame.
    func evaluateSequenceStart() {
        lock.lock(); defer { lock.unlock() }
        let count = Self.onScreenNormalWindowCount()
        if count > 0 {
            spreadSeen = false
            yieldsForSequence = false
        } else {
            yieldsForSequence = spreadSeen
            if spreadSeen {
                // Logged while armed so a no-yield outcome (windows still
                // listed during Show Desktop) is diagnosable too.
                LauncherDiagnostics.shared.record(
                    "gesture-touch",
                    "desktop-check count=\(count) spread=1 yields=\(yieldsForSequence ? 1 : 0)"
                )
            }
        }
    }

    var yields: Bool {
        lock.lock(); defer { lock.unlock() }
        return yieldsForSequence
    }

    func endSequence() {
        lock.lock(); defer { lock.unlock() }
        yieldsForSequence = false
    }

    /// Normal (layer 0) windows currently on screen. Query failure reports
    /// `Int.max` so a broken call can never wrongly suppress our own gesture.
    private static func onScreenNormalWindowCount() -> Int {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else {
            return Int.max
        }
        return list.filter { ($0[kCGWindowLayer as String] as? Int) == 0 }.count
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
    // Calibration context for palm-vs-finger discrimination (see armLag/paird).
    private var episodeStart: TimeInterval?
    private var lastContactAt: TimeInterval?
    private var armLag: TimeInterval?
    private var initialPairs: [CGFloat] = []
    private var latestCenters: [CGPoint] = []
    private var latestRecords: [[Float]] = []
    private var firstDipFrame: Int?
    private var rawDumpBudget = 10

    enum FrameAction {
        case ignore
        case arm
        case qualityReject
    }

    /// A sequence stays believable only while nearly every frame keeps its
    /// four distinct contacts. Observed distributions: genuine pinches hold
    /// 97–99.6% qualified frames; palm-interloper sequences sit at 69–82% with
    /// the dips interleaved from early on. 12% sits in the empty gap between
    /// the two clusters, and 12 frames (~0.1s) lets the guard trip well before
    /// a swipe can build commit-level motion.
    private static let qualityMinimumFrames = 12
    private static let qualityMaximumDipRatio = 0.12

    /// Records one processed frame. Counters only arm once a qualifying
    /// (four-cluster) frame appears, so ordinary one-finger use never accumulates.
    @discardableResult
    func noteFrame(
        raw: Int,
        clusters: Int,
        qualified: Bool,
        centers: [CGPoint],
        records: [[Float]] = []
    ) -> FrameAction {
        lock.lock(); defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        if armedSince == nil {
            // Track the touch episode while cold: armLag measures how long
            // contacts were already present before the four-count arrived
            // (palm-first patterns arm with a large lag).
            if clusters > 0 {
                if let last = lastContactAt, now - last <= 0.1 {
                    // Continuation of the current touch episode.
                } else {
                    episodeStart = now
                }
                lastContactAt = now
            }
            guard qualified else { return .ignore }
            armedSince = now
            armLag = episodeStart.map { now - $0 } ?? -1
            initialPairs = Self.sortedPairDistances(centers)
            latestCenters = centers
            latestRecords = records
            frames += 1
            qualifiedFrames += 1
            rawHistogram[raw, default: 0] += 1
            clusterHistogram[clusters, default: 0] += 1
            if rawDumpBudget > 0 {
                rawDumpBudget -= 1
                emitRawDumpLocked(records, tag: "arm")
            }
            return .arm
        }
        frames += 1
        if qualified {
            qualifiedFrames += 1
            if centers.count == 4 { latestCenters = centers }
            if !records.isEmpty { latestRecords = records }
        } else {
            if firstDipFrame == nil { firstDipFrame = frames }
            let dipRatio = 1.0 - Double(qualifiedFrames) / Double(max(frames, 1))
            if frames >= Self.qualityMinimumFrames, dipRatio > Self.qualityMaximumDipRatio {
                return .qualityReject
            }
        }
        rawHistogram[raw, default: 0] += 1
        clusterHistogram[clusters, default: 0] += 1
        return .ignore
    }

    private func emitRawDumpLocked(_ records: [[Float]], tag: String) {
        guard !records.isEmpty else { return }
        let body = records.enumerated().map { index, floats in
            let values = floats.map { String(format: "%.4f", $0) }.joined(separator: ",")
            return "c\(index)=[\(values)]"
        }.joined(separator: " ")
        LauncherDiagnostics.shared.record("gesture-touch", "raw-record \(tag) n=\(records.count) \(body)")
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
        let qualifiedRatio = Double(qualifiedFrames) / Double(max(frames, 1))
        var line = "end=\(event.outcome.rawValue)"
            + " gen=\(event.generation)"
            + " dur=\(fixed(now - since))"
            + " motion=\(fixed(event.motion))"
            + " frames=\(frames) qualified=\(qualifiedFrames)"
            + String(format: " qr=%.2f", qualifiedRatio)
            + " dip@=\(firstDipFrame.map(String.init) ?? "-")"
            + " raw=\(histogramText(rawHistogram))"
            + " clusters=\(histogramText(clusterHistogram))"
            + " other-drops=\(otherDeviceDrops)"
        line += String(format: " armLag=%.3f", armLag ?? -1)
        if initialPairs.count == 6, latestCenters.count == 4 {
            let latest = Self.sortedPairDistances(latestCenters)
            if latest.count == 6 {
                let deltas = zip(latest, initialPairs)
                    .map { String(format: "%.3f", $0 - $1) }
                    .joined(separator: ",")
                line += " paird={\(deltas)}"
            }
        }
        // Sequences worth a raw-record dump without any user cooperation:
        // real motion, non-pinch topology churn, or a slow palm-style arm.
        if rawDumpBudget > 0,
           event.motion >= 0.03 || qualifiedRatio < 0.95 || (armLag ?? 0) > 0.15 {
            rawDumpBudget -= 1
            emitRawDumpLocked(latestRecords, tag: "end")
        }
        armedSince = nil
        frames = 0
        qualifiedFrames = 0
        otherDeviceDrops = 0
        rawHistogram = [:]
        clusterHistogram = [:]
        armLag = nil
        initialPairs = []
        latestCenters = []
        latestRecords = []
        firstDipFrame = nil
        LauncherDiagnostics.shared.record("gesture-touch", line)
    }

    /// Sorted pairwise distances of a four-contact set: the first three are
    /// the intra-group gaps, the last three the spread-out pairs.
    private static func sortedPairDistances(_ centers: [CGPoint]) -> [CGFloat] {
        guard centers.count == 4 else { return [] }
        var distances: [CGFloat] = []
        for index in 0..<4 {
            for other in (index + 1)..<4 {
                distances.append(hypot(
                    centers[index].x - centers[other].x,
                    centers[index].y - centers[other].y
                ))
            }
        }
        return distances.sorted()
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
        GestureTouchDiagnostics.shared.noteFrame(
            raw: rawCount, clusters: 0, qualified: false, centers: []
        )
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
            if rawCount >= 4, TrackpadContactState.shared.hasClaimedPinch {
                gate.suppress(for: 0.6)
            }
            return
        }
        points.append(CGPoint(x: x, y: y))
    }

    let centers = TrackpadContactClustering.centers(of: points)
    let qualified = centers.count == 4
    var records: [[Float]] = []
    if qualified {
        // Buffered for the interesting-sequence dump: full records of the
        // four-contact frames, used to locate a size/area field offline.
        records.reserveCapacity(min(rawCount, maximumTrackedContacts))
        for index in 0..<min(rawCount, maximumTrackedContacts) {
            let record = contacts.advanced(by: index * 96)
            var floats: [Float] = []
            floats.reserveCapacity(24)
            for offset in stride(from: 0, to: 96, by: 4) {
                floats.append(record.load(fromByteOffset: offset, as: Float.self))
            }
            records.append(floats)
        }
    }
    switch GestureTouchDiagnostics.shared.noteFrame(
        raw: rawCount, clusters: centers.count, qualified: qualified,
        centers: centers, records: records
    ) {
    case .ignore:
        break
    case .arm:
        // Arming dump already emitted inside noteFrame (budgeted); decide
        // now whether this sequence yields to Show Desktop.
        DesktopYieldGate.shared.evaluateSequenceStart()
    case .qualityReject:
        // Too many frames lost their four distinct contacts — a palm-style
        // interloper sequence, not a pinch. Kill it before motion can commit.
        TrackpadContactState.shared.rejectContact(at: now)
        ContactDeviceOwnership.shared.releaseIfIdle()
        return
    }

    guard qualified else {
        // Four or more *distinct* fingers still matter for the attempt (they
        // arm the candidate), but system events are only held back once the
        // pinch claim threshold is crossed — a spread must stay the system's.
        if centers.count >= 4, TrackpadContactState.shared.hasClaimedPinch {
            gate.suppress(for: 0.6)
        }
        TrackpadContactState.shared.endContact(contactCount: centers.count, at: now)
        ContactDeviceOwnership.shared.releaseIfIdle()
        return
    }

    if let device { ContactDeviceOwnership.shared.claim(device) }
    gate.pendingBeginGesture = false

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
    if let snap = TrackpadContactState.shared.snapshot(),
       snap.motion <= -DesktopYieldGate.spreadMotion {
        DesktopYieldGate.shared.noteDeliberateSpread()
    }
    if let generation = TrackpadContactState.shared.noteQualifiedFrame(radius: radius, at: now),
       !DesktopYieldGate.shared.yields {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                LauncherController.shared.rawTrackpadGestureBegan(generation: generation)
            }
        }
    }
    // Hold system gestures back only once this contact's motion is
    // unambiguously a pinch — evaluated after the frame that may have
    // crossed the threshold. While yielding, the system keeps everything.
    if TrackpadContactState.shared.hasClaimedPinch, !DesktopYieldGate.shared.yields {
        gate.suppress(for: 0.6)
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
            DesktopYieldGate.shared.endSequence()
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

    /// The live contact crossed the animator's begin threshold in the pinch
    /// direction; only now may the tap swallow system gesture events. While a
    /// sequence yields to Show Desktop, never — the system's exit pinch has
    /// priority.
    nonisolated static var hasClaimedPinch: Bool {
        TrackpadContactState.shared.hasClaimedPinch && !DesktopYieldGate.shared.yields
    }

    /// True while the current sequence defers to Show Desktop.
    nonisolated static var yieldsToDesktop: Bool {
        DesktopYieldGate.shared.yields
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
