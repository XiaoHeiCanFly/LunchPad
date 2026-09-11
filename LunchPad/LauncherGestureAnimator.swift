import AppKit
import QuartzCore

/// Display-link-driven launcher progress engine.
///
/// Two states drive every transition:
///   - `.tracking`: fingers are on the trackpad. The visual follows the finger
///     target with a short time-constant exponential low-pass filter — near
///     instant follow that still smooths 120 Hz sensor jitter.
///   - `.settling`: after release, a spring continues toward 0 (closed) or
///     1 (open) with the finger's final velocity.
///
/// All visuals are applied by the controller through `onVisualChange` by
/// mutating CALayer properties directly. The engine never publishes state, so
/// a gesture never re-evaluates a SwiftUI view.
@MainActor
final class LauncherGestureAnimator {
    enum State: Equatable {
        case idle
        case tracking
        case settling(target: CGFloat)
    }

    private(set) var state: State = .idle
    private(set) var visualProgress: CGFloat = 0

    // MARK: - Tunables

    /// Full-spread radius change (raw trackpad units) mapping to progress 0→1.
    static let rawSensitivity: CGFloat = 0.095
    /// NSEvent magnification sensitivity (1 / 2.15 — matches the pre-refactor
    /// `-magnification * 2.15` factor).
    static let magnifySensitivity: CGFloat = 0.465
    /// Time constant (seconds) of the tracking low-pass filter.
    static let followTau: TimeInterval = 0.016
    /// Both directions commit after the same fraction of travel. A short
    /// velocity projection helps a deliberate flick, without changing the
    /// rules based on how long the fingers have been down.
    static let commitTravel: CGFloat = 0.35
    static let projectionTime: TimeInterval = 0.12
    static let maximumProjection: CGFloat = 0.18

    /// Spring for opening (near-critical → fast settle ~0.2s, imperceptible
    /// bounce). The old values (300/38) were over-damped, so the scale crept
    /// asymptotically toward 1.0 and the keyboard/dock open felt floaty.
    static let openStiffness: CGFloat = 700
    static let openDamping: CGFloat = 50
    /// Spring for closing (near-critical → clean, minimal bounce), slightly
    /// stiffer than opening so dismissal feels quicker.
    static let closeStiffness: CGFloat = 850
    static let closeDamping: CGFloat = 56

    /// Maximum time a settle may run before it is forced to finish.
    static let maxSettleDuration: TimeInterval = 1.1
    /// A CADisplayLink tied to a display that went away can remain non-nil but
    /// stop delivering frames. Detect that case without delaying an explicit
    /// launcher invocation by seconds.
    static let firstFrameWatchdogDelay: TimeInterval = 0.12

    // MARK: - Wiring (set by LauncherController)

    /// Called every display frame with the smoothed/spring progress.
    var onVisualChange: ((CGFloat) -> Void)?
    /// Called once per gesture when the fingers have moved meaningfully — the
    /// controller prepares and presents the panels here.
    var onGestureBegin: (() -> Void)?
    /// Called once when a settle finishes. `didOpen` reports the result.
    var onSettleComplete: ((Bool) -> Void)?
    var onGestureRelease: ((CGFloat, CGFloat, CGFloat) -> Void)?

    // MARK: - Private state

    private var displayLink: CADisplayLink?
    /// The physical display the current CADisplayLink was created from. A
    /// display link does not migrate when that display is unplugged.
    private var displayID: Int?
    private var baseProgress: CGFloat = 0
    /// Read target and contact lifetime together, so lifting cannot erase the
    /// last position between two reads. Timestamps use system uptime.
    struct TrackingSample {
        var target: CGFloat
        var timestamp: TimeInterval
        var contactActive: Bool = true
    }

    private var trackingTargetProvider: (() -> TrackingSample)?
    private var restingTarget: CGFloat = 0
    private var latestTarget: CGFloat = 0
    private var latestInputTarget: CGFloat = 0
    private var latestSampleTime: TimeInterval = 0
    private var fingerVelocity: CGFloat = 0
    private var velocity: CGFloat = 0
    private var lastFrameTime: TimeInterval?
    private var settleStartTime: TimeInterval = 0
    private var didBeginGesture = false
    private var settleTarget: CGFloat = 0
    /// Invalidates delayed watchdog work whenever a newer transition starts.
    private var transitionGeneration: UInt = 0

    // MARK: - Lifecycle

    func start(on screen: NSScreen?) {
        _ = retarget(on: screen)
    }

    /// Recreates the display link when the presentation display changes.
    /// `CADisplayLink` remains tied to the NSScreen that created it; retaining
    /// the old object after unplugging an external monitor leaves a valid,
    /// non-nil link that never emits another frame.
    @discardableResult
    func retarget(on requestedScreen: NSScreen?) -> Bool {
        guard let screen = requestedScreen ?? NSScreen.main else { return false }
        let requestedID = Self.identifier(for: screen)
        guard displayLink == nil || displayID != requestedID else { return false }

        let shouldRun = state != .idle
        displayLink?.invalidate()
        let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        link.isPaused = !shouldRun
        displayLink = link
        displayID = requestedID
        return true
    }

    func stop() {
        cancelTransition()
        displayLink?.invalidate()
        displayLink = nil
        displayID = nil
    }

    private static func identifier(for screen: NSScreen) -> Int {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue
            ?? screen.hashValue
    }

    // MARK: - Gesture API

    /// A new contact can catch an in-flight spring at its visible position.
    /// The previous destination remains the resting state if it is cancelled.
    func beginTracking(base: CGFloat, targetProvider: @escaping () -> TrackingSample) {
        let previousDestination: CGFloat
        if case .settling(let target) = state {
            previousDestination = target
        } else {
            previousDestination = base >= 0.5 ? 1 : 0
        }
        cancelTransition()
        baseProgress = min(1, max(0, base))
        restingTarget = previousDestination
        trackingTargetProvider = targetProvider
        latestTarget = baseProgress
        latestInputTarget = baseProgress
        latestSampleTime = 0
        fingerVelocity = 0
        velocity = 0
        didBeginGesture = false
        state = .tracking
        resumeLink()
        // Contact lifetime owns tracking. In particular, a slow gesture or a
        // stationary hold must never be completed by a fixed-duration timer.
    }

    /// Consume the terminal sample before making a decision. The last sensor
    /// update may arrive after the last display frame, including a fast pinch
    /// that begins and ends between two frames.
    func endTracking(cancelled: Bool = false, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard state == .tracking else { return }
        let generation = transitionGeneration
        if let sample = trackingTargetProvider?() { record(sample) }
        guard state == .tracking, transitionGeneration == generation else { return }
        let releaseVelocity = currentFingerVelocity(at: now)
        let projected = latestTarget + min(Self.maximumProjection, max(-Self.maximumProjection,
            releaseVelocity * Self.projectionTime))
        let destination: CGFloat
        if cancelled || !didBeginGesture {
            destination = restingTarget
        } else if restingTarget > 0.5 {
            destination = projected <= 1 - Self.commitTravel ? 0 : 1
        } else {
            destination = projected >= Self.commitTravel ? 1 : 0
        }
        onGestureRelease?(latestTarget, releaseVelocity, destination)
        guard state == .tracking, transitionGeneration == generation else { return }
        beginSettling(to: destination, initialVelocity: cancelled ? 0 : releaseVelocity)
    }

    private func record(_ sample: TrackingSample) {
        guard sample.target.isFinite, sample.timestamp.isFinite,
              sample.timestamp >= latestSampleTime else { return }
        // Discard travel beyond either endpoint. Reversing a fully open or
        // closed gesture must respond immediately, without unwinding an
        // invisible amount of extra pinch/spread first.
        let target = min(1, max(0, latestTarget + sample.target - latestInputTarget))
        if latestSampleTime > 0, sample.timestamp > latestSampleTime {
            let dt = sample.timestamp - latestSampleTime
            // Filter sensor velocity, not visual lag. Long holds discard old
            // momentum; tiny intervals cannot turn jitter into a huge fling.
            let measured = (target - latestTarget) / max(1.0 / 240.0, dt)
            let k = 1 - exp(-dt / 0.04)
            fingerVelocity += (min(4, max(-4, measured)) - fingerVelocity) * k
        }
        latestTarget = target
        latestInputTarget = sample.target
        latestSampleTime = sample.timestamp
        if !didBeginGesture, abs(target - baseProgress) >= 0.02 {
            didBeginGesture = true
            onGestureBegin?()
        }
    }

    private func currentFingerVelocity(at now: TimeInterval) -> CGFloat {
        // Keep momentum across the brief contact-loss grace, but do not fling
        // after the user has stopped moving and held the gesture in place.
        let age = max(0, now - latestSampleTime - 0.08)
        return fingerVelocity * exp(-age / 0.04)
    }

    /// Spring from the current progress to `target` (0 or 1).
    func beginSettling(to target: CGFloat, initialVelocity: CGFloat = 0) {
        cancelTransition()
        velocity = initialVelocity
        settleTarget = target
        settleStartTime = ProcessInfo.processInfo.systemUptime
        state = .settling(target: target)
        resumeLink()
        let generation = transitionGeneration
        let startingProgress = visualProgress

        // CADisplayLink may silently stop after a display/Space lifecycle
        // change. If not even the first frame arrives, complete immediately so
        // the ordered panels cannot remain fully transparent.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.firstFrameWatchdogDelay) { [weak self] in
            guard let self,
                  self.transitionGeneration == generation,
                  self.state == .settling(target: target),
                  abs(self.visualProgress - startingProgress) < 0.0001 else { return }
            self.finishSettling()
        }

        // The frame-based timeout cannot fire when the display link itself is
        // stalled, so keep an independent main-run-loop deadline as a second
        // line of defence.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.maxSettleDuration) { [weak self] in
            guard let self,
                  self.transitionGeneration == generation,
                  self.state == .settling(target: target) else { return }
            self.finishSettling()
        }
    }

    /// Non-gesture instant jump.
    func snap(to value: CGFloat) {
        cancelTransition()
        visualProgress = value
        velocity = 0
        onVisualChange?(value)
    }

    /// Stop everything without calling any completion.
    func cancel() {
        cancelTransition()
    }

    var isActive: Bool { state != .idle }
    var isTracking: Bool { state == .tracking }

    // MARK: - Display link

    @objc private func tick(_ link: CADisplayLink) {
        let now = ProcessInfo.processInfo.systemUptime
        let interval = link.targetTimestamp - link.timestamp
        advanceFrame(at: now, duration: interval > 0 ? interval : 1.0 / 60.0)
    }

    /// Also used by deterministic gesture replay tests, without a display.
    func advanceFrame(at now: TimeInterval, duration: TimeInterval) {
        let dt = min(1.0 / 15.0, max(1.0 / 240.0, lastFrameTime.map { now - $0 } ?? duration))
        lastFrameTime = now
        switch state {
        case .tracking:
            let generation = transitionGeneration
            guard let sample = trackingTargetProvider?() else {
                endTracking(at: now)
                return
            }
            record(sample)
            // Preparing windows may cancel tracking during a screen change.
            // Do not let an old display frame overwrite that transition.
            guard state == .tracking, transitionGeneration == generation else { return }
            if !sample.contactActive {
                endTracking(at: now)
                return
            }
            let k = 1 - exp(-dt / Self.followTau)
            visualProgress += (latestTarget - visualProgress) * k
            onVisualChange?(visualProgress)

        case .settling(let target):
            let stiffness = target > 0 ? Self.openStiffness : Self.closeStiffness
            let damping = target > 0 ? Self.openDamping : Self.closeDamping
            // Bounded substeps keep the spring stable on dropped frames and
            // low-refresh displays as well as 120 Hz ProMotion.
            let steps = max(1, Int(ceil(dt / (1.0 / 120.0))))
            let step = dt / Double(steps)
            for _ in 0..<steps {
                let acceleration = -stiffness * (visualProgress - target) - damping * velocity
                velocity += acceleration * step
                visualProgress += velocity * step
            }
            onVisualChange?(visualProgress)
            if now - settleStartTime > Self.maxSettleDuration
                || (abs(visualProgress - target) < 0.003 && abs(velocity) < 0.15) {
                finishSettling()
            }

        case .idle:
            break
        }
    }

    private func finishSettling() {
        let didOpen = settleTarget > 0.5
        visualProgress = settleTarget
        velocity = 0
        state = .idle
        transitionGeneration &+= 1
        trackingTargetProvider = nil
        lastFrameTime = nil
        pauseLink()
        onVisualChange?(settleTarget)
        onSettleComplete?(didOpen)
    }

    private func cancelTransition() {
        transitionGeneration &+= 1
        state = .idle
        trackingTargetProvider = nil
        lastFrameTime = nil
        pauseLink()
    }

    private func resumeLink() {
        displayLink?.isPaused = false
    }

    private func pauseLink() {
        displayLink?.isPaused = true
    }
}
