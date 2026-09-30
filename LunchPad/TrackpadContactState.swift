import Foundation

/// The callback thread publishes an entire sample under one lock. Readers
/// never combine the position from one contact with another contact's state.
nonisolated final class TrackpadContactState: @unchecked Sendable {
    struct Snapshot: Sendable {
        let generation: UInt64
        let motion: CGFloat
        let contactActive: Bool
        /// Uptime of the last valid radius measurement. Release preserves it
        /// so a lift cannot masquerade as another motion sample.
        let timestamp: TimeInterval
    }

    static let shared = TrackpadContactState()
    static let contactLossGrace: TimeInterval = 0.12

    /// One line of contact-lifecycle telemetry. `candidateAbort` carries
    /// generation 0: no contact ever began.
    struct TerminalEvent: Sendable {
        enum Outcome: String, Sendable {
            case lifted = "lift"
            case topologyTimeout = "topology-timeout"
            case cancelled = "cancel"
            case candidateAbort = "candidate-abort"
        }
        let outcome: Outcome
        let generation: UInt64
        let motion: CGFloat
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
    private var lastSampleUptime: TimeInterval = 0
    private var contactLossBeganAt: TimeInterval?
    private var candidateLastQualifiedAt: TimeInterval?
    private var candidateQualifiedDuration: TimeInterval = 0
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
        return contactIsActive || candidateLastQualifiedAt != nil
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

    /// The raw-trackpad callback's entry point for frames whose contact set
    /// qualifies as four fingers. The first `stableBeginDuration` of such
    /// frames only arms a candidate; any non-qualifying frame disarms it, so
    /// one stray four-count frame never begins a gesture.
    @discardableResult
    func noteQualifiedFrame(
        radius: CGFloat,
        at now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> UInt64? {
        guard radius.isFinite, radius >= 0, now.isFinite else { return nil }
        lock.lock(); defer { lock.unlock() }
        expireContactIfNeededLocked(now: now)
        if contactIsActive {
            return noteActiveFrameLocked(radius: radius, at: now)
        }
        if let last = candidateLastQualifiedAt, now - last <= Self.qualifiedFrameGap {
            candidateQualifiedDuration += min(now - last, 0.05)
        } else if candidateLastQualifiedAt != nil {
            candidateQualifiedDuration = 0
        }
        candidateLastQualifiedAt = now
        guard candidateQualifiedDuration >= Self.stableBeginDuration else { return nil }
        return beginContactLocked(radius: radius, at: now)
    }

    private func noteActiveFrameLocked(radius: CGFloat, at now: TimeInterval) -> UInt64? {
        if contactLossBeganAt == nil {
            // Positive motion is a pinch; negative motion is a spread.
            accumulatedMotion += latestRadius - radius
        }
        // On recovery from a short 3/5-finger frame, the four-contact centroid
        // may have changed. Rebase without introducing a progress jump.
        latestRadius = radius
        lastSampleUptime = now
        contactLossBeganAt = nil
        return nil
    }

    private func beginContactLocked(radius: CGFloat, at now: TimeInterval) -> UInt64 {
        generation &+= 1
        // Zero denotes the absence of any contact.
        if generation == 0 { generation = 1 }
        accumulatedMotion = 0
        latestRadius = radius
        contactIsActive = true
        contactIsCancelled = false
        contactLossBeganAt = nil
        lastSampleUptime = now
        candidateLastQualifiedAt = nil
        candidateQualifiedDuration = 0
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
                candidateLastQualifiedAt = nil
                candidateQualifiedDuration = 0
                emitTerminalLocked(TerminalEvent(outcome: .candidateAbort, generation: 0, motion: 0))
            }
            return
        }
        if contactCount == 0 {
            finishContactLocked(outcome: .lifted)
            return
        }
        // Grace starts at an observed topology change, never at the last
        // position update. A stationary hand may stop producing callbacks.
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
        candidateLastQualifiedAt = nil
        candidateQualifiedDuration = 0
        if contactIsActive { finishContactLocked(outcome: .cancelled) }
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
        emitTerminalLocked(TerminalEvent(outcome: outcome, generation: generation, motion: accumulatedMotion))
    }

    private func emitTerminalLocked(_ event: TerminalEvent) {
        terminalEventHandler?(event)
    }

    private func currentSnapshotLocked() -> Snapshot {
        Snapshot(
            generation: generation,
            motion: accumulatedMotion,
            contactActive: contactIsActive,
            timestamp: lastSampleUptime
        )
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
