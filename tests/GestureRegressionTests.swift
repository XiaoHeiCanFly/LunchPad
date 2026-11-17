import AppKit
import Foundation

/// Exercises the production state machines without a display link, hardware,
/// sleeps, or event delivery. All frame and contact times are explicitly replayed.
@main
@MainActor
struct GestureRegressionTests {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    static func near(_ actual: CGFloat, _ expected: CGFloat, tolerance: CGFloat = 0.000_001,
                     _ message: String) throws {
        try require(actual.isFinite && abs(actual - expected) <= tolerance,
                    "\(message): expected \(expected), got \(actual)")
    }

    final class SampleBox {
        var sample: LauncherGestureAnimator.TrackingSample
        init(_ sample: LauncherGestureAnimator.TrackingSample) { self.sample = sample }
    }

    final class Events {
        var began = 0
        var releases: [(target: CGFloat, velocity: CGFloat, destination: CGFloat)] = []
        var completions: [Bool] = []
    }

    final class Replay {
        let animator = LauncherGestureAnimator()
        let box: SampleBox
        let events = Events()
        var now = ProcessInfo.processInfo.systemUptime

        init(base: CGFloat) {
            box = SampleBox(.init(target: base, timestamp: now))
            animator.snap(to: base)
            animator.onGestureBegin = { [events] in events.began += 1 }
            animator.onGestureRelease = { [events] in events.releases.append(($0, $1, $2)) }
            animator.onSettleComplete = { [events] in events.completions.append($0) }
            animator.beginTracking(base: base) { [box] in box.sample }
            animator.advanceFrame(at: now, duration: 1.0 / 120.0)
        }

        func move(to target: CGFloat, after duration: TimeInterval, frame: Bool = true) {
            now += duration
            box.sample = .init(target: target, timestamp: now)
            if frame { animator.advanceFrame(at: now, duration: duration) }
        }

        /// Stationary hardware can stop publishing samples entirely.
        func hold(for duration: TimeInterval, hz: Double = 120) throws {
            let count = max(1, Int(ceil(duration * hz)))
            let dt = duration / Double(count)
            for _ in 0..<count {
                now += dt
                animator.advanceFrame(at: now, duration: dt)
                try require(animator.isTracking, "Holding contact completed the gesture")
            }
            try require(events.completions.isEmpty, "Holding contact emitted a completion")
        }

        func release(cancelled: Bool = false, after duration: TimeInterval = 0) {
            now += duration
            box.sample.contactActive = false
            animator.endTracking(cancelled: cancelled, at: now)
        }

        func assertDestination(_ target: CGFloat) throws {
            try require(events.releases.count == 1, "Expected exactly one release")
            try near(events.releases[0].destination, target, "Release destination")
            try require(animator.state == .settling(target: target), "Incorrect settling state")
        }
    }

    static func slowHeldGestures() throws {
        for base: CGFloat in [0, 1] {
            let replay = Replay(base: base)
            let end: CGFloat = base == 0 ? 0.52 : 0.48
            for step in 1...720 {
                replay.move(to: base + (end - base) * CGFloat(step) / 720, after: 1.0 / 120.0)
                try require(replay.animator.isTracking, "Six-second drag stopped following contact")
            }
            try replay.hold(for: 6)
            try near(replay.animator.visualProgress, end, "Held gesture position")
            try require(replay.events.began == 1, "Gesture must begin once")
            replay.release()
            try replay.assertDestination(1 - base)
        }
    }

    static func terminalSampleWithoutFrame() throws {
        for base: CGFloat in [0, 1] {
            let replay = Replay(base: base)
            let end: CGFloat = base == 0 ? 0.45 : 0.55
            replay.move(to: end, after: 0.5, frame: false)
            replay.release()
            try replay.assertDestination(1 - base)
            try near(replay.events.releases[0].target, end, "Terminal sensor sample")
            try require(replay.events.began == 1, "Between-frame gesture must still begin")
        }
    }

    static func durationIndependentRelease() throws {
        for duration in [0.15, 0.35, 0.7, 1.5, 6.0] {
            for base: CGFloat in [0, 1] {
                for travel: CGFloat in [0.34, 0.36, 0.52] {
                    let replay = Replay(base: base)
                    let end = base == 0 ? travel : 1 - travel
                    for step in 1...30 {
                        replay.move(to: base + (end - base) * CGFloat(step) / 30,
                                    after: duration / 30)
                    }
                    try replay.hold(for: 0.5)
                    replay.release()
                    try replay.assertDestination(travel >= 0.35 ? 1 - base : base)
                }
            }
        }
    }

    static func reversalsIgnoreHistoricalExtrema() throws {
        for base: CGFloat in [0, 1] {
            let replay = Replay(base: base)
            replay.move(to: base == 0 ? 0.82 : 0.18, after: 0.25)
            replay.move(to: base == 0 ? 0.08 : 0.92, after: 0.3)
            try replay.hold(for: 0.2)
            replay.release()
            try replay.assertDestination(base)
        }
    }

    static func deliberateFlickAndPausedHold() throws {
        for base: CGFloat in [0, 1] {
            for pause in [false, true] {
                let replay = Replay(base: base)
                for travel: CGFloat in [0.04, 0.11, 0.23] {
                    replay.move(to: base == 0 ? travel : 1 - travel, after: 0.02)
                }
                if pause { try replay.hold(for: 0.5) }
                replay.release()
                try replay.assertDestination(pause ? base : 1 - base)
                let speed = abs(replay.events.releases[0].velocity)
                try require(pause ? speed < 0.001 : speed > 1,
                            "Release velocity must distinguish a flick from a stationary hold")
            }
        }
    }

    static func cancellationRestoresRestingState() throws {
        for base: CGFloat in [0, 1] {
            let replay = Replay(base: base)
            replay.move(to: 1 - base, after: 0.2)
            replay.release(cancelled: true)
            try replay.assertDestination(base)
        }
    }

    static func reversingAfterSaturationHasNoDeadTravel() throws {
        for base: CGFloat in [0, 1] {
            let replay = Replay(base: base)
            replay.move(to: base == 0 ? 1.8 : -0.8, after: 0.2)
            try replay.hold(for: 0.2)
            try near(replay.animator.visualProgress, 1 - base, tolerance: 0.000_01,
                     "Overspread must clamp visible progress")
            replay.move(to: base == 0 ? 1.7 : -0.7, after: 0.1)
            try replay.hold(for: 0.2)
            let reversed: CGFloat = base == 0 ? 0.9 : 0.1
            try near(replay.animator.visualProgress, reversed, tolerance: 0.000_01,
                     "Reversal after overspread must move immediately")
            replay.release()
            try near(replay.events.releases[0].target, reversed,
                     "Repeated terminal sampling must not apply motion twice")
            try replay.assertDestination(1 - base)
        }
    }

    static func grabbingSpringPreservesContinuity() throws {
        for destination: CGFloat in [0, 1] {
            let animator = LauncherGestureAnimator()
            animator.snap(to: 1 - destination)
            animator.beginSettling(to: destination)
            var now = ProcessInfo.processInfo.systemUptime
            for _ in 0..<5 {
                now += 1.0 / 120.0
                animator.advanceFrame(at: now, duration: 1.0 / 120.0)
            }
            let caughtPosition = animator.visualProgress
            try require(caughtPosition > 0 && caughtPosition < 1, "Spring must be in flight")
            let box = SampleBox(.init(target: caughtPosition, timestamp: now))
            animator.beginTracking(base: caughtPosition) { box.sample }
            try near(animator.visualProgress, caughtPosition, "Grabbing the spring jumped immediately")
            now += 1.0 / 120.0
            animator.advanceFrame(at: now, duration: 1.0 / 120.0)
            try near(animator.visualProgress, caughtPosition, "Grabbing the spring jumped on its first frame")
            box.sample = .init(target: 1 - destination, timestamp: now + 0.1)
            animator.endTracking(cancelled: true, at: now + 0.1)
            try require(animator.state == .settling(target: destination),
                        "Cancelling a caught spring must restore its original destination")
        }
    }

    static func stableSpringsAcrossFrameRates() throws {
        let schedules: [(String, [TimeInterval])] = [
            ("120 Hz", [1.0 / 120.0]), ("60 Hz", [1.0 / 60.0]),
            ("30 Hz", [1.0 / 30.0]),
            ("dropped frames", [1.0 / 120.0, 1.0 / 60.0, 0.15, 1.0 / 30.0])
        ]
        for (name, schedule) in schedules {
            for destination: CGFloat in [0, 1] {
                for initialVelocity: CGFloat in [-4, 0, 4] {
                    let animator = LauncherGestureAnimator()
                    let events = Events()
                    animator.onSettleComplete = { events.completions.append($0) }
                    animator.snap(to: 1 - destination)
                    animator.beginSettling(to: destination, initialVelocity: initialVelocity)
                    let start = ProcessInfo.processInfo.systemUptime
                    var now = start
                    for frame in 0..<300 where animator.isActive {
                        let dt = schedule[frame % schedule.count]
                        now += dt
                        animator.advanceFrame(at: now, duration: dt)
                        let value = animator.visualProgress
                        try require(value.isFinite && value > -0.15 && value < 1.15,
                                    "Unstable \(name) spring: \(value)")
                    }
                    try require(animator.state == .idle, "\(name) spring failed to settle")
                    try require(now - start < 1.3, "\(name) spring took too long")
                    try near(animator.visualProgress, destination, "Final \(name) spring value")
                    try require(events.completions == [destination == 1],
                                "\(name) spring must emit exactly one completion")
                    animator.advanceFrame(at: now + 1, duration: 1)
                    try require(events.completions.count == 1, "Idle frame repeated completion")
                }
            }
        }
    }

    static func stationaryContactAndExplicitRelease() throws {
        let contact = TrackpadContactState()
        try require(contact.snapshot(at: 100) == nil, "Contact must begin empty")
        let generation = contact.updateContact(radius: 0.2, at: 100)!
        contact.updateContact(radius: 0.15, at: 100.2)
        let held = contact.snapshot(for: generation, at: 112)!
        try require(held.contactActive, "Silence must not be treated as lift")
        try near(held.motion, 0.05, "Stationary accumulated motion")
        contact.endContact(contactCount: 0, at: 112.1)
        let released = contact.snapshot(for: generation, at: 112.1)!
        try require(!released.contactActive, "Zero contacts must end immediately")
        try near(released.motion, held.motion, "Lift erased the terminal movement")
        try require(released.timestamp == held.timestamp, "Lift invented a movement timestamp")
    }

    static func topologyRecoveryRebasesContinuously() throws {
        for changedCount in [3, 5] {
            let contact = TrackpadContactState()
            let generation = contact.updateContact(radius: 0.2, at: 100)!
            contact.updateContact(radius: 0.16, at: 100.1)
            // A long stationary hold before topology loss must not consume the grace period.
            contact.endContact(contactCount: changedCount, at: 106)
            try require(contact.snapshot(for: generation, at: 106.05)!.contactActive,
                        "\(changedCount)-finger loss did not receive its grace period")
            let newGeneration = contact.updateContact(radius: 0.3, at: 106.06)
            try require(newGeneration == nil, "Short loss unexpectedly started a new generation")
            try near(contact.snapshot(for: generation, at: 106.06)!.motion, 0.04,
                     "\(changedCount)-finger recovery jumped with its changed centroid")
            contact.updateContact(radius: 0.29, at: 106.08)
            try near(contact.snapshot(for: generation, at: 106.08)!.motion, 0.05,
                     "Motion after rebasing")
            contact.endContact(contactCount: changedCount, at: 107)
            try require(!contact.snapshot(for: generation,
                                          at: 107 + TrackpadContactState.contactLossGrace + 0.01)!.contactActive,
                        "Sustained \(changedCount)-finger loss must finish after grace")
        }
    }

    static func generationsKeepFrozenTerminalSamples() throws {
        let contact = TrackpadContactState()
        let first = contact.updateContact(radius: 0.2, at: 100)!
        contact.updateContact(radius: 0.14, at: 100.1)
        contact.endContact(contactCount: 0, at: 100.2)
        let second = contact.updateContact(radius: 0.3, at: 101)!
        try require(second != first, "New contact must have a distinct generation")
        contact.updateContact(radius: 0.34, at: 101.1)
        let frozen = contact.snapshot(for: first, at: 101.1)!
        try require(!frozen.contactActive && frozen.generation == first,
                    "Previous gesture read the current gesture's lifecycle")
        try near(frozen.motion, 0.06, "Previous gesture's final motion changed")
        try require(frozen.timestamp == 100.1, "Previous generation's timestamp changed")
        try near(contact.snapshot(for: second, at: 101.1)!.motion, -0.04,
                 "New contact inherited previous motion")
        contact.endContact(contactCount: 0, at: 101.2)
        for offset in 2...20 {
            let now = 100 + Double(offset)
            contact.updateContact(radius: 0.2, at: now)
            contact.endContact(contactCount: 0, at: now + 0.1)
        }
        try require(contact.snapshot(for: first, at: 130) == nil,
                    "Evicted generations must return nil, never a newer contact")
    }

    static func lifecycleCancellationInvalidatesQueuedBegins() throws {
        for releaseFirst in [false, true] {
            let contact = TrackpadContactState()
            let generation = contact.updateContact(radius: 0.2, at: 100)!
            contact.updateContact(radius: 0.16, at: 100.1)
            if releaseFirst { contact.endContact(contactCount: 0, at: 100.2) }
            contact.cancelContact(at: 100.3)
            contact.cancelContact(at: 100.4)
            try require(contact.snapshot(at: 100.5) == nil,
                        "Lifecycle cancellation must invalidate a queued unbound begin")
            let terminal = contact.snapshot(for: generation, at: 100.5)!
            try require(!terminal.contactActive, "Lifecycle cancellation must end existing tracking")
            try near(terminal.motion, 0.04, "Lifecycle cancellation discarded terminal motion")
            try require(terminal.timestamp == 100.1, "Cancellation invented a movement timestamp")
            let nextGeneration = contact.updateContact(radius: 0.3, at: 101)!
            try require(nextGeneration != generation, "Recovery needs a new generation")
            let recovered = contact.snapshot(at: 101)!
            try require(recovered.contactActive && recovered.generation == nextGeneration,
                        "New contact must recover normally after cancellation")
            try near(recovered.motion, 0, "Recovered contact must start at a fresh baseline")
            try require(!contact.snapshot(for: generation, at: 101)!.contactActive,
                        "Recovery revived the cancelled generation")
        }
    }

    static func contactAndAnimatorRetainBetweenFrameMotion() throws {
        for base: CGFloat in [0, 1] {
            let contact = TrackpadContactState()
            let animator = LauncherGestureAnimator()
            let events = Events()
            var now = ProcessInfo.processInfo.systemUptime
            let generation = contact.updateContact(radius: 0.2, at: now)!
            animator.snap(to: base)
            animator.onGestureRelease = { events.releases.append(($0, $1, $2)) }
            animator.beginTracking(base: base) {
                let sample = contact.snapshot(for: generation, at: now)!
                return .init(target: base + sample.motion / LauncherGestureAnimator.rawSensitivity,
                             timestamp: sample.timestamp, contactActive: sample.contactActive)
            }
            animator.advanceFrame(at: now, duration: 1.0 / 120.0)
            now += 0.5
            contact.updateContact(radius: base == 0 ? 0.155 : 0.245, at: now)
            contact.endContact(contactCount: 0, at: now + 0.001)
            // A new hand can arrive before the old consumer sees the lift.
            contact.updateContact(radius: 0.4, at: now + 0.002)
            contact.updateContact(radius: 0.35, at: now + 0.003)
            now += 0.01
            animator.advanceFrame(at: now, duration: 1.0 / 60.0)
            try require(events.releases.count == 1, "Terminal contact must release once")
            let expected = base + (base == 0 ? 0.045 : -0.045) / LauncherGestureAnimator.rawSensitivity
            try near(events.releases[0].target, expected, "Animator lost final generation's movement")
            try near(events.releases[0].destination, 1 - base, "Integrated release destination")
        }
    }

    static func presentationCancellationCannotReviveTracking() throws {
        for releaseBeforeFrame in [false, true] {
            let replay = Replay(base: 0)
            replay.animator.onGestureBegin = { [animator = replay.animator] in
                // A display/window rebuild can synchronously reset progress.
                animator.snap(to: 0)
            }
            replay.move(to: 0.6, after: 0.3, frame: !releaseBeforeFrame)
            if releaseBeforeFrame { replay.release() }
            try require(replay.animator.state == .idle, "Cancelled presentation restarted tracking")
            try near(replay.animator.visualProgress, 0, "Old frame overwrote reset progress")
            try require(replay.events.releases.isEmpty, "Cancelled presentation emitted a release")
        }
    }

    static func contactClusteringCollapsesSplitFingers() throws {
        // One rolling finger reported twice among four distinct fingers.
        let splitHand = [
            CGPoint(x: 0.30, y: 0.50),
            CGPoint(x: 0.31, y: 0.51),
            CGPoint(x: 0.45, y: 0.50),
            CGPoint(x: 0.60, y: 0.50),
            CGPoint(x: 0.75, y: 0.50)
        ]
        try require(TrackpadContactClustering.centers(of: splitHand).count == 4,
                    "A split finger must collapse into one contact")
        // Three fingers where one is split must still count as three.
        let threeWithSplit = [
            CGPoint(x: 0.30, y: 0.50),
            CGPoint(x: 0.31, y: 0.51),
            CGPoint(x: 0.55, y: 0.50),
            CGPoint(x: 0.80, y: 0.50)
        ]
        try require(TrackpadContactClustering.centers(of: threeWithSplit).count == 3,
                    "Three fingers with a split must not count as four")
        let fourDistinct = [
            CGPoint(x: 0.30, y: 0.50),
            CGPoint(x: 0.45, y: 0.50),
            CGPoint(x: 0.60, y: 0.50),
            CGPoint(x: 0.75, y: 0.50)
        ]
        try require(TrackpadContactClustering.centers(of: fourDistinct).count == 4,
                    "Distinct fingertips must never merge")
    }

    static func hand(radius: CGFloat, center: CGPoint = CGPoint(x: 0.5, y: 0.5)) -> FourFingerGeometry {
        FourFingerGeometry(centers: [
            CGPoint(x: center.x + radius, y: center.y),
            CGPoint(x: center.x - radius, y: center.y),
            CGPoint(x: center.x, y: center.y + radius),
            CGPoint(x: center.x, y: center.y - radius)
        ])
    }

    static func stableBeginRejectsTransientFourFrames() throws {
        let contact = TrackpadContactState()
        // A single stray four-count frame must not begin a gesture.
        try require(contact.noteQualifiedFrame(hand(radius: 0.2), at: 100) == nil,
                    "One stray frame began a contact")
        try require(contact.snapshot(at: 100.5) == nil,
                    "Stray frame produced a generation")
        // Any non-qualifying frame disarms the candidate completely.
        contact.endContact(contactCount: 3, at: 100.01)
        contact.noteQualifiedFrame(hand(radius: 0.2), at: 101.0)
        try require(contact.noteQualifiedFrame(hand(radius: 0.18), at: 101.01) == nil
                        && contact.noteQualifiedFrame(hand(radius: 0.16), at: 101.02) == nil,
                    "Candidate began before the stability window elapsed")
        let generation = contact.noteQualifiedFrame(hand(radius: 0.16), at: 101.04)
        try require(generation != nil, "Sustained four-contact frames must claim a coherent pinch")
        try near(contact.snapshot(for: generation, at: 101.04)!.motion, 0.04,
                 "Confirmation dropped candidate motion")
        // A long gap between qualified frames restarts the window.
        let restarted = TrackpadContactState()
        restarted.noteQualifiedFrame(hand(radius: 0.3), at: 200.0)
        restarted.noteQualifiedFrame(hand(radius: 0.28), at: 200.02)
        try require(restarted.noteQualifiedFrame(hand(radius: 0.2), at: 200.2) == nil,
                    "A stale candidate survived a frame gap")
        try require(restarted.noteQualifiedFrame(hand(radius: 0.18), at: 200.22) == nil,
                    "Restarted candidate must re-earn its stability window")
        try require(restarted.noteQualifiedFrame(hand(radius: 0.16), at: 200.24) != nil,
                    "Fresh sustained frames must begin after restart")
        try near(restarted.snapshot(at: 200.24)!.motion, 0.04, "Frame gap reused the old baseline")
    }

    static func directionalClaimRequiresCoherentMotion() throws {
        let start = ProcessInfo.processInfo.systemUptime
        for allowsSpread in [false, true] {
            let contact = TrackpadContactState()
            for index in 0..<5 {
                let now = start + Double(index) * 0.012
                contact.noteQualifiedFrame(hand(radius: 0.17 + CGFloat(index) * 0.01),
                                           allowsSpread: allowsSpread, at: now)
            }
            try require(contact.hasClaimedGesture == allowsSpread,
                        "Spread should be reserved for the system while the launcher is closed")
            if allowsSpread {
                contact.noteQualifiedFrame(hand(radius: 0.22), at: start + 0.06)
                contact.noteQualifiedFrame(hand(radius: 0.16), at: start + 0.07)
                try require(contact.hasClaimedGesture, "Reversal lost the existing claim")
            }
        }

        for translation in [true, false] {
            let contact = TrackpadContactState()
            for index in 0..<6 {
                let now = start + Double(index) * 0.012
                let center = CGPoint(x: 0.35 + (translation ? CGFloat(index) * 0.04 : 0), y: 0.5)
                let radius: CGFloat = translation || index == 0 ? 0.2 : 0.15
                try require(contact.noteQualifiedFrame(hand(radius: radius, center: center), at: now) == nil,
                            "Four-finger translation or a single sample jump claimed the gesture")
            }
        }

        let thumbPinch = TrackpadContactState()
        let otherFingers = [
            CGPoint(x: 0.30, y: 0.60),
            CGPoint(x: 0.45, y: 0.60),
            CGPoint(x: 0.60, y: 0.60)
        ]
        for index in 0..<5 {
            let now = start + Double(index) * 0.012
            let thumb = CGPoint(x: 0.45, y: 0.20 + CGFloat(index) * 0.025)
            thumbPinch.noteQualifiedFrame(FourFingerGeometry(centers: otherFingers + [thumb]), at: now)
        }
        try require(thumbPinch.hasClaimedGesture, "Three agreeing thumb distances should confirm a pinch")

        let yielding = TrackpadContactState()
        for index in 0..<5 {
            let now = start + Double(index) * 0.012
            let radius = 0.2 - CGFloat(index) * 0.01
            try require(yielding.noteQualifiedFrame(hand(radius: radius), allowsClaim: false, at: now) == nil,
                        "A contact yielding to Show Desktop claimed the gesture")
        }
    }

    static func staggeredLiftAndRepeatedTopologyLoss() throws {
        for recovers in [false, true] {
            let contact = TrackpadContactState()
            let start = ProcessInfo.processInfo.systemUptime
            var generation: UInt64?
            for index in 0..<8 {
                let now = start + Double(index) * 0.01
                let radius = 0.24 - CGFloat(index) * 0.01
                if let claimed = contact.noteQualifiedFrame(hand(radius: radius), at: now) {
                    generation = claimed
                }
            }
            try require(generation != nil, "Test pinch must earn a claim")
            contact.endContact(contactCount: 3, at: start + 0.08)
            contact.endContact(contactCount: 3, at: start + 0.09)
            if recovers {
                contact.noteQualifiedFrame(hand(radius: 0.18), at: start + 0.10)
            }
            contact.endContact(contactCount: 2, at: start + 0.11)
            if recovers {
                contact.noteQualifiedFrame(hand(radius: 0.18), at: start + 0.12)
            } else {
                contact.endContact(contactCount: 0, at: start + 0.12)
            }
            let terminal = contact.snapshot(for: generation, at: start + 0.12)!
            try require(!terminal.contactActive, "The contact should have ended")
            try require(terminal.cancelled == recovers,
                        "Repeated recovered dips must cancel, while a staggered lift must release normally")
            try near(terminal.motion, 0.07, "Partial-contact frames changed the last valid travel")

            let replay = Replay(base: 0)
            replay.move(to: 0.45, after: 0.08)
            replay.box.sample = .init(target: terminal.motion / LauncherGestureAnimator.rawSensitivity,
                                      timestamp: replay.now + 0.01,
                                      contactActive: false, cancelled: terminal.cancelled)
            replay.animator.advanceFrame(at: replay.now + 0.02, duration: 0.02)
            try replay.assertDestination(recovers ? 0 : 1)
        }
    }

    static func main() {
        let tests: [(String, () throws -> Void)] = [
            ("slow drags and stationary holds remain under finger control", slowHeldGestures),
            ("release consumes movement newer than the last display frame", terminalSampleWithoutFrame),
            ("commit threshold is independent of gesture duration", durationIndependentRelease),
            ("reversal uses current intent instead of historical extrema", reversalsIgnoreHistoricalExtrema),
            ("flick projection assists motion and expires during a hold", deliberateFlickAndPausedHold),
            ("cancelled gestures restore their resting state", cancellationRestoresRestingState),
            ("reversing after saturation responds immediately and release is idempotent", reversingAfterSaturationHasNoDeadTravel),
            ("grabbing a spring preserves position and cancellation destination", grabbingSpringPreservesContinuity),
            ("springs settle at 120, 60, 30 Hz and across dropped frames", stableSpringsAcrossFrameRates),
            ("stationary contacts persist and explicit lift retains motion", stationaryContactAndExplicitRelease),
            ("three/five-contact loss recovers without a centroid jump", topologyRecoveryRebasesContinuously),
            ("generations retain frozen terminal samples", generationsKeepFrozenTerminalSamples),
            ("lifecycle cancellation invalidates queued begins and allows recovery", lifecycleCancellationInvalidatesQueuedBegins),
            ("raw contact and animator preserve a between-frame release", contactAndAnimatorRetainBetweenFrameMotion),
            ("presentation cancellation cannot revive an old frame or release", presentationCancellationCannotReviveTracking),
            ("split fingers cluster to a stable contact count", contactClusteringCollapsesSplitFingers),
            ("four-contact stability retains early travel and resets after a frame gap", stableBeginRejectsTransientFourFrames),
            ("only coherent directional motion can claim a four-finger gesture", directionalClaimRequiresCoherentMotion),
            ("staggered lift releases and repeated topology loss cancels", staggeredLiftAndRepeatedTopologyLoss)
        ]
        var failures = 0
        for (name, test) in tests {
            do {
                try test()
                print("PASS \(name)")
            } catch {
                failures += 1
                print("FAIL \(name): \(error)")
            }
        }
        print("\(tests.count - failures)/\(tests.count) gesture regression groups passed")
        if failures > 0 { exit(1) }
    }
}
