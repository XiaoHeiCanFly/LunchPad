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
            try require(!contact.snapshot(for: generation, at: 107.08)!.contactActive,
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
            ("presentation cancellation cannot revive an old frame or release", presentationCancellationCannotReviveTracking)
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
