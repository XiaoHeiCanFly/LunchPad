import AppKit
import QuartzCore

/// Display-link-driven launcher progress engine.
///
/// Two states drive every transition:
///   - `.tracking`: fingers are on the trackpad. The visual follows the finger
///     target with a short time-constant exponential low-pass filter — near
///     instant follow that still smooths 120 Hz sensor jitter.
///   - `.settling`: a spring integrates toward 0 (closed) or 1 (open),
///     producing the native overshoot when opening and a clean scale-down
///     when closing.
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
    /// Tuned so the launcher becomes visible with only a small finger travel —
    /// a responsive pinch start (see also the fade-in curve in applyVisualChange).
    static let rawSensitivity: CGFloat = 0.095
    /// NSEvent magnification sensitivity (1 / 2.15 — matches the pre-refactor
    /// `-magnification * 2.15` factor).
    static let magnifySensitivity: CGFloat = 0.465
    /// Time constant (seconds) of the tracking low-pass filter.
    static let followTau: TimeInterval = 0.025
    /// Progress at/above which releasing settles open.
    static let openThreshold: CGFloat = 0.35
    /// For a QUICK spread to commit OPEN, the raw target must reach at least
    /// this high. Quick gestures are more likely accidental flicks than
    /// sustained ones, so the bar sits above `openThreshold` — but a fast,
    /// deliberate large spread still opens instead of snapping shut on release.
    static let quickOpenThreshold: CGFloat = 0.6
    /// A contact shorter than this counts as a quick flick. Quick flicks only
    /// commit when their amplitude is large enough to be deliberate — see
    /// quickCloseDrop.
    static let quickGestureDuration: TimeInterval = 0.45
    /// For a SUSTAINED spread to close, the raw target must drop at least this
    /// far below the open base (1.0). Small — any deliberate spread closes.
    static let closeDropEpsilon: CGFloat = 0.02
    /// For a QUICK spread, the target must drop at least this far below the
    /// open base to count as a deliberate close. This keeps a quick large
    /// spread closing while a quick small flick still settles back to open.
    static let quickCloseDrop: CGFloat = 0.25

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
    /// Raw MultitouchSupport occasionally misses the final contact frame
    /// (sleep/wake and display reconfiguration are the common cases). Never
    /// allow that stale contact to own the animator indefinitely.
    static let maxTrackingDuration: TimeInterval = 5
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

    // MARK: - Private state

    private var displayLink: CADisplayLink?
    /// The physical display the current CADisplayLink was created from. A
    /// display link does not migrate when that display is unplugged.
    private var displayID: Int?
    private var baseProgress: CGFloat = 0
    /// Farthest targets (raw, unfiltered) the fingers reached during tracking.
    /// Used at release to judge gesture direction without the low-pass lag.
    private var trackingMinTarget: CGFloat = 0
    private var trackingMaxTarget: CGFloat = 0
    private var trackingTargetProvider: (() -> CGFloat)?
    /// Polled each frame while `.tracking`; returning false ends the gesture.
    /// Set to `nil` for magnify (release is signaled via `endTracking`).
    var trackingContactActive: (() -> Bool)?
    private var velocity: CGFloat = 0
    private var gestureStartTime: Date = .distantPast
    private var settleStartTime: Date = .distantPast
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

    /// Begin following a trackpad (or magnify) gesture. `base` is the launcher
    /// state when the gesture starts: 1 if already presented, 0 otherwise.
    /// `targetProvider` is read once per display frame and must return the
    /// absolute finger target in [0, 1].
    func beginTracking(base: CGFloat, targetProvider: @escaping () -> CGFloat) {
        cancelTransition()
        baseProgress = base
        trackingTargetProvider = targetProvider
        trackingMinTarget = base
        trackingMaxTarget = base
        velocity = 0
        gestureStartTime = Date()
        didBeginGesture = false
        state = .tracking
        resumeLink()
        let generation = transitionGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.maxTrackingDuration) { [weak self] in
            guard let self,
                  self.transitionGeneration == generation,
                  self.state == .tracking else { return }
            // Treat an abnormally long raw contact as released. endTracking()
            // retains the normal threshold/direction decision, so recovery is
            // visually identical to lifting the fingers.
            self.endTracking()
        }
    }

    /// Called when the fingers lift. Judged by how far the raw target moved:
    /// a spread while open closes (a quick spread needs a large enough drop to
    /// count as deliberate, a sustained spread closes on any real movement);
    /// a pinch while closed opens once it reaches openThreshold. A quick pinch
    /// never commits.
    func endTracking() {
        guard state == .tracking else { return }
        let isQuick = Date().timeIntervalSince(gestureStartTime) < Self.quickGestureDuration
        if baseProgress > 0.5 {
            // Spread to close while open. The close threshold is intentionally
            // removed — amplitude decides, not magnitude:
            //   - sustained: any real spread closes
            //   - quick: must spread far enough to be deliberate, not a flick
            let dropped = baseProgress - trackingMinTarget
            let minimum = isQuick ? Self.quickCloseDrop : Self.closeDropEpsilon
            beginSettling(to: dropped >= minimum ? 0 : 1)
        } else if isQuick {
            // A quick spread commits to open only when it is large enough to be
            // deliberate (a quick small flick is likely accidental). Previously
            // a quick gesture NEVER committed, so a fast, large spread animated
            // most of the way open and then snapped shut on release.
            beginSettling(to: trackingMaxTarget >= Self.quickOpenThreshold ? 1 : 0)
        } else {
            beginSettling(to: trackingMaxTarget >= Self.openThreshold ? 1 : 0)
        }
    }

    /// Spring from the current progress to `target` (0 or 1).
    func beginSettling(to target: CGFloat) {
        cancelTransition()
        settleTarget = target
        settleStartTime = Date()
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
        let dt = max(1.0 / 120.0, link.duration)
        switch state {
        case .tracking:
            if let active = trackingContactActive, !active() {
                endTracking()
                return
            }
            guard let provider = trackingTargetProvider else {
                endTracking()
                return
            }
            let target = min(1, max(0, provider()))
            trackingMinTarget = min(trackingMinTarget, target)
            trackingMaxTarget = max(trackingMaxTarget, target)
            let k = 1 - exp(-dt / Self.followTau)
            let previous = visualProgress
            visualProgress += (target - visualProgress) * k
            velocity = (visualProgress - previous) / dt
            if !didBeginGesture, abs(target - baseProgress) >= 0.02 {
                didBeginGesture = true
                onGestureBegin?()
            }
            onVisualChange?(visualProgress)

        case .settling(let target):
            let stiffness = target > 0 ? Self.openStiffness : Self.closeStiffness
            let damping = target > 0 ? Self.openDamping : Self.closeDamping
            let acceleration = -stiffness * (visualProgress - target) - damping * velocity
            velocity += acceleration * dt
            visualProgress += velocity * dt
            onVisualChange?(visualProgress)
            if Date().timeIntervalSince(settleStartTime) > Self.maxSettleDuration
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
        trackingContactActive = nil
        pauseLink()
        onVisualChange?(settleTarget)
        onSettleComplete?(didOpen)
    }

    private func cancelTransition() {
        transitionGeneration &+= 1
        state = .idle
        trackingTargetProvider = nil
        trackingContactActive = nil
        pauseLink()
    }

    private func resumeLink() {
        displayLink?.isPaused = false
    }

    private func pauseLink() {
        displayLink?.isPaused = true
    }
}
