import Foundation

/// The callback thread publishes an entire sample under one lock. Readers
/// never combine the position from one contact with another contact's state.
nonisolated final class TrackpadContactState: @unchecked Sendable {
    struct Snapshot: Sendable {
        let generation: UInt64
        let motion: CGFloat
        let contactActive: Bool
        let cancelled: Bool
        /// Uptime of the last valid radius measurement. Release preserves it
        /// so a lift cannot masquerade as another motion sample.
        let timestamp: TimeInterval
    }

    static let shared = TrackpadContactState()
    static let contactLossGrace: TimeInterval = 0.12
    /// Minimum net travel in raw radius units, matching the animator's 2%
    /// presentation threshold. Pair distances must also agree with the motion.
    static let claimMotion: CGFloat = 0.0019
    private static let minimumRadiusStep: CGFloat = 0.00025
    private static let qualityMinimumFrames = 12
    private static let qualityMaximumDipRatio = 0.12

    /// One line of contact-lifecycle telemetry. `candidateAbort` carries
    /// generation 0: no contact ever began.
    struct TerminalEvent: Sendable {
        enum Outcome: String, Sendable {
            case lifted = "lift"
            case topologyTimeout = "topology-timeout"
            case cancelled = "cancel"
            case candidateAbort = "candidate-abort"
            case qualityAbort = "quality-abort"
        }
        let outcome: Outcome
        let generation: UInt64
        let candidateMotion: CGFloat
        let peakMotion: CGFloat
        let motion: CGFloat
        let claimed: Bool
    }
    /// A gesture only begins after this much uninterrupted four-contact time,
    /// so a single stray frame (finger split, palm edge) cannot hijack a
    /// three-finger gesture.
    static let stableBeginDuration: TimeInterval = 0.030
    /// Qualified frames further apart than this are a new attempt, not the
    /// same one continuing through a delivery gap.
    static let qualifiedFrameGap: TimeInterval = 0.04

    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var latestRadius: CGFloat = 0
    private var accumulatedMotion: CGFloat = 0
    private var contactIsActive = false
    private var contactIsCancelled = false
    private var gestureClaimed = false
    private var lastSampleUptime: TimeInterval = 0
    private var contactLossBeganAt: TimeInterval?
    private var candidateStartedAt: TimeInterval?
    private var candidateLastQualifiedAt: TimeInterval?
    private var baseline: FourFingerGeometry?
    private var directionStepRadius: CGFloat = 0
    private var pinchSteps = 0
    private var spreadSteps = 0
    private var candidateMotion: CGFloat = 0
    private var peakMotion: CGFloat = 0
    private var validFrames = 0
    private var invalidFrames = 0
    private var recoveredLosses = 0
    private var completedContacts: [UInt64: Snapshot] = [:]
    private var completedGenerations: [UInt64] = []
    /// Invoked under the state lock, once per terminal transition — keep the
    /// handler cheap (a single diagnostic line).
    private var terminalEventHandler: ((TerminalEvent) -> Void)?

    /// Old terminal samples cover queued main-thread wakeups and the last
    /// display frame of the previous gesture. An evicted generation returns
    /// nil; it can never silently read a newer gesture's motion.
    private static let retainedContactCount = 16

    func snapshot(
        for requestedGeneration: UInt64? = nil,
        at now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Snapshot? {
        lock.lock(); defer { lock.unlock() }
        expireContactIfNeededLocked(now: now)
        guard generation != 0 else { return nil }
        // A delayed begin must not revive a contact cancelled by sleep.
        guard requestedGeneration != nil || !contactIsCancelled else { return nil }
        if let requestedGeneration, requestedGeneration != generation {
            return completedContacts[requestedGeneration]
        }
        return currentSnapshotLocked()
    }

    var contactActive: Bool { snapshot()?.contactActive ?? false }

    /// True while a contact OR an unstarted four-finger candidate owns the
    /// state machine; the device-ownership gate must not release in between.
    var hasPendingState: Bool {
        lock.lock(); defer { lock.unlock() }
        expireContactIfNeededLocked(now: ProcessInfo.processInfo.systemUptime)
        return contactIsActive || candidateLastQualifiedAt != nil
    }

    /// Once claimed, the same live contact owns the gesture through reversals.
    var hasClaimedGesture: Bool {
        lock.lock(); defer { lock.unlock() }
        expireContactIfNeededLocked(now: ProcessInfo.processInfo.systemUptime)
        return contactIsActive && gestureClaimed
    }

    /// Set once before any device frames arrive (monitor `start()`).
    func setTerminalEventHandler(_ handler: @escaping (TerminalEvent) -> Void) {
        lock.lock(); defer { lock.unlock() }
        terminalEventHandler = handler
    }

    /// Returns a generation only when a new contact begins. The caller uses
    /// this value for its one main-thread wakeup and all subsequent samples.
    @discardableResult
    func updateContact(
        radius: CGFloat,
        at now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> UInt64? {
        guard radius.isFinite, radius >= 0, now.isFinite else { return nil }
        lock.lock(); defer { lock.unlock() }
        expireContactIfNeededLocked(now: now)
        if !contactIsActive {
            return beginContactLocked(radius: radius, at: now)
        }
        return noteActiveFrameLocked(radius: radius, at: now)
    }

    /// Accumulate travel from the first stable geometry. Return the generation
    /// once, when a coherent direction has earned a claim.
    @discardableResult
    func noteQualifiedFrame(
        _ geometry: FourFingerGeometry,
        allowsSpread: Bool = false,
        allowsClaim: Bool = true,
        at now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> UInt64? {
        let radius = geometry.radius
        guard radius.isFinite, radius >= 0, now.isFinite else { return nil }
        lock.lock(); defer { lock.unlock() }
        expireContactIfNeededLocked(now: now)
        if contactIsActive {
            validFrames += 1
            if contactLossBeganAt != nil {
                recoveredLosses += 1
                let totalFrames = validFrames + invalidFrames
                // A trailing run of lost contacts is a lift. Evaluate quality
                // only after repeated gaps that actually recover to four.
                if recoveredLosses >= 2, totalFrames >= Self.qualityMinimumFrames,
                   Double(invalidFrames) / Double(totalFrames) > Self.qualityMaximumDipRatio {
                    contactIsCancelled = true
                    finishContactLocked(outcome: .qualityAbort)
                    return nil
                }
                if !gestureClaimed {
                    resetDirectionLocked(to: geometry)
                    accumulatedMotion = 0
                }
            } else if !gestureClaimed {
                recordDirectionStepLocked(to: radius)
            }
            noteActiveFrameLocked(radius: radius, at: now)
        } else {
            if let last = candidateLastQualifiedAt,
               now >= last, now - last <= Self.qualifiedFrameGap {
                recordDirectionStepLocked(to: radius)
                validFrames += 1
            } else {
                candidateStartedAt = now
                resetDirectionLocked(to: geometry)
                validFrames = 1
            }
            latestRadius = radius
            candidateLastQualifiedAt = now
            guard let start = candidateStartedAt, now - start >= Self.stableBeginDuration,
                  let baseline else { return nil }
            let frames = validFrames
            _ = beginContactLocked(radius: radius, at: now, initialMotion: baseline.radius - radius)
            validFrames = frames
        }
        guard allowsClaim, !gestureClaimed, let baseline else { return nil }
        let direction: CGFloat = accumulatedMotion < 0 ? -1 : 1
        let steps = direction > 0 ? pinchSteps : spreadSteps
        guard direction > 0 || allowsSpread,
              abs(accumulatedMotion) >= Self.claimMotion, steps >= 2,
              geometry.supportsMotion(from: baseline, direction: direction) else { return nil }
        gestureClaimed = true
        return generation
    }

    private func resetDirectionLocked(to geometry: FourFingerGeometry) {
        baseline = geometry
        directionStepRadius = geometry.radius
        pinchSteps = 0
        spreadSteps = 0
    }

    private func recordDirectionStepLocked(to radius: CGFloat) {
        let step = directionStepRadius - radius
        guard abs(step) >= Self.minimumRadiusStep else { return }
        if step > 0 { pinchSteps += 1 } else { spreadSteps += 1 }
        directionStepRadius = radius
    }

    @discardableResult
    private func noteActiveFrameLocked(radius: CGFloat, at now: TimeInterval) -> UInt64? {
        if contactLossBeganAt == nil {
            // Positive motion is a pinch; negative motion is a spread.
            accumulatedMotion += latestRadius - radius
            if abs(accumulatedMotion) > abs(peakMotion) { peakMotion = accumulatedMotion }
        }
        // On recovery from a short 3/5-finger frame, the four-contact centroid
        // may have changed. Rebase without introducing a progress jump.
        latestRadius = radius
        lastSampleUptime = now
        contactLossBeganAt = nil
        return nil
    }

    private func beginContactLocked(radius: CGFloat, at now: TimeInterval, initialMotion: CGFloat = 0) -> UInt64 {
        generation &+= 1
        // Zero denotes the absence of any contact.
        if generation == 0 { generation = 1 }
        accumulatedMotion = initialMotion
        candidateMotion = initialMotion
        peakMotion = initialMotion
        latestRadius = radius
        contactIsActive = true
        contactIsCancelled = false
        gestureClaimed = false
        contactLossBeganAt = nil
        lastSampleUptime = now
        candidateStartedAt = nil
        candidateLastQualifiedAt = nil
        validFrames = 0
        invalidFrames = 0
        recoveredLosses = 0
        return generation
    }

    func endContact(
        contactCount: Int,
        at now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        guard now.isFinite else { return }
        lock.lock(); defer { lock.unlock() }
        guard contactIsActive else {
            // Any non-qualifying frame disarms an unstarted candidate.
            if candidateLastQualifiedAt != nil {
                finishCandidateLocked(outcome: .candidateAbort)
            }
            return
        }
        if contactCount == 0 {
            finishContactLocked(outcome: .lifted)
            return
        }
        // Grace starts at an observed topology change, never at the last
        // position update. A stationary hand may stop producing callbacks.
        invalidFrames += 1
        if contactLossBeganAt == nil { contactLossBeganAt = now }
        expireContactIfNeededLocked(now: now)
    }

    /// Lifecycle cancellation is explicit; a held hand has no timeout.
    /// Existing readers retain a terminal sample, while queued begin callbacks
    /// can no longer discover this contact as the current gesture.
    func cancelContact(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard now.isFinite else { return }
        lock.lock(); defer { lock.unlock() }
        contactIsCancelled = true
        if contactIsActive {
            finishContactLocked(outcome: .cancelled)
        } else if candidateLastQualifiedAt != nil {
            finishCandidateLocked(outcome: .cancelled)
        }
    }

    private func finishCandidateLocked(outcome: TerminalEvent.Outcome) {
        let motion = (baseline?.radius ?? latestRadius) - latestRadius
        candidateStartedAt = nil
        candidateLastQualifiedAt = nil
        emitTerminalLocked(TerminalEvent(
            outcome: outcome, generation: 0, candidateMotion: motion,
            peakMotion: motion, motion: motion, claimed: false
        ))
    }

    private func expireContactIfNeededLocked(now: TimeInterval) {
        guard contactIsActive, let contactLossBeganAt,
              now - contactLossBeganAt >= Self.contactLossGrace else { return }
        finishContactLocked(outcome: .topologyTimeout)
    }

    private func finishContactLocked(outcome: TerminalEvent.Outcome) {
        contactIsActive = false
        contactLossBeganAt = nil
        // Keep the final radius change until the consumer samples the lift.
        completedContacts[generation] = currentSnapshotLocked()
        completedGenerations.append(generation)
        if completedGenerations.count > Self.retainedContactCount {
            completedContacts.removeValue(forKey: completedGenerations.removeFirst())
        }
        emitTerminalLocked(TerminalEvent(
            outcome: outcome, generation: generation, candidateMotion: candidateMotion,
            peakMotion: peakMotion, motion: accumulatedMotion, claimed: gestureClaimed
        ))
    }

    private func emitTerminalLocked(_ event: TerminalEvent) {
        terminalEventHandler?(event)
    }

    private func currentSnapshotLocked() -> Snapshot {
        Snapshot(
            generation: generation,
            motion: accumulatedMotion,
            contactActive: contactIsActive,
            cancelled: contactIsCancelled,
            timestamp: lastSampleUptime
        )
    }
}

/// The pair distances describe hand shape independently of translation,
/// rotation, and the order in which the trackpad reports the four contacts.
nonisolated struct FourFingerGeometry {
    let radius: CGFloat
    let pairDistances: [CGFloat]

    init(centers: [CGPoint]) {
        let count = CGFloat(centers.count)
        let x = centers.reduce(0) { $0 + $1.x } / count
        let y = centers.reduce(0) { $0 + $1.y } / count
        radius = centers.reduce(0) { $0 + hypot($1.x - x, $1.y - y) } / count
        pairDistances = Self.sortedPairDistances(centers)
    }

    func supportsMotion(from baseline: Self, direction: CGFloat) -> Bool {
        var supportingPairs = 0
        var supportingTravel: CGFloat = 0
        var opposingTravel: CGFloat = 0
        for (current, start) in zip(pairDistances, baseline.pairDistances) {
            let travel = (start - current) * direction
            if travel >= 0.003 { supportingPairs += 1 }
            supportingTravel += max(0, travel)
            opposingTravel += max(0, -travel)
        }
        // A thumb moving toward three stable fingers can contribute three
        // pairs. A lateral slip tends to shorten some and lengthen others.
        return supportingPairs >= 3 && supportingTravel >= 2 * opposingTravel
    }

    static func sortedPairDistances(_ centers: [CGPoint]) -> [CGFloat] {
        var distances: [CGFloat] = []
        for index in centers.indices {
            for other in (index + 1)..<centers.count {
                distances.append(hypot(centers[index].x - centers[other].x,
                                       centers[index].y - centers[other].y))
            }
        }
        return distances.sorted()
    }
}

/// Collapses near-coincident contacts before counting fingers. One physical
/// finger rolling over the pad is often reported as two overlapping contacts,
/// which turns a three-finger gesture into a bogus four-count frame; distinct
/// fingertips are a fingertip-width apart (~0.12+ in normalized units), well
/// above `mergeDistance`.
nonisolated enum TrackpadContactClustering {
    static let mergeDistance: CGFloat = 0.08

    static func centers(
        of points: [CGPoint],
        mergeDistance: CGFloat = TrackpadContactClustering.mergeDistance
    ) -> [CGPoint] {
        var leaders: [CGPoint] = []
        var members: [[CGPoint]] = []
        for point in points {
            if let index = leaders.firstIndex(where: {
                hypot($0.x - point.x, $0.y - point.y) <= mergeDistance
            }) {
                members[index].append(point)
                let cluster = members[index]
                let count = CGFloat(cluster.count)
                leaders[index] = CGPoint(
                    x: cluster.reduce(0) { $0 + $1.x } / count,
                    y: cluster.reduce(0) { $0 + $1.y } / count
                )
            } else {
                leaders.append(point)
                members.append([point])
            }
        }
        return leaders
    }
}
