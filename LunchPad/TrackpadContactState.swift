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
    static let contactLossGrace: TimeInterval = 0.075

    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var latestRadius: CGFloat = 0
    private var accumulatedMotion: CGFloat = 0
    private var contactIsActive = false
    private var contactIsCancelled = false
    private var lastSampleUptime: TimeInterval = 0
    private var contactLossBeganAt: TimeInterval?
    private var completedContacts: [UInt64: Snapshot] = [:]
    private var completedGenerations: [UInt64] = []

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
            generation &+= 1
            // Zero denotes the absence of any contact.
            if generation == 0 { generation = 1 }
            accumulatedMotion = 0
            latestRadius = radius
            contactIsActive = true
            contactIsCancelled = false
            contactLossBeganAt = nil
            lastSampleUptime = now
            return generation
        }

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

    func endContact(
        contactCount: Int,
        at now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        guard now.isFinite else { return }
        lock.lock(); defer { lock.unlock() }
        guard contactIsActive else { return }
        if contactCount == 0 {
            finishContactLocked()
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
        if contactIsActive { finishContactLocked() }
    }

    private func expireContactIfNeededLocked(now: TimeInterval) {
        guard contactIsActive, let contactLossBeganAt,
              now - contactLossBeganAt >= Self.contactLossGrace else { return }
        finishContactLocked()
    }

    private func finishContactLocked() {
        contactIsActive = false
        contactLossBeganAt = nil
        // Keep the final radius change until the consumer samples the lift.
        completedContacts[generation] = currentSnapshotLocked()
        completedGenerations.append(generation)
        if completedGenerations.count > Self.retainedContactCount {
            completedContacts.removeValue(forKey: completedGenerations.removeFirst())
        }
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
