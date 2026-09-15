/// Loads a value once and hands it to everyone who asks, including callers
/// who arrive while the load is still running.
///
/// **An actor alone does not do this, and believing it did was the bug.**
/// Swift actors are *reentrant across `await`*: mutual exclusion covers one
/// turn on the actor, not a sequence spanning a suspension. So the obvious
///
/// ```swift
/// if let loaded { return loaded }      // caller B also sees nil here
/// loaded = try await load()            // …because A is suspended on this
/// ```
///
/// lets every caller that arrives during the load start its own. With
/// `ModelContainer` that is a second 2.3 GB load, or 17.2 GB on the 30B
/// option, resident at the same time.
///
/// The fix is to publish the *work* and not just the result: the in-flight
/// `Task` is stored before the first `await`, which is a plain actor-isolated
/// assignment and cannot be interleaved, so a later caller has something to
/// join. Generic and separate from `MLXTokenProducer` because that is the only
/// way this is testable at all — `ModelContainer` needs 2.3 GB of weights and
/// a Metal device, and the rule above is a decision, which `AGENTS.md` keeps
/// on the tested side of every seam.
actor LoadOnce<Loaded: Sendable> {
    private var loaded: Loaded?
    private var inFlight: Task<Loaded, Error>?

    /// What is already loaded. Never starts a load, so a caller that needs
    /// "ready or not" gets an answer without waiting minutes for one.
    var existing: Loaded? { loaded }

    /// The value, loading it with `load` if this is the first ask.
    func value(_ load: @Sendable @escaping () async throws -> Loaded) async throws -> Loaded {
        if let loaded { return loaded }
        // Someone else is already doing it. Awaiting their task is what makes
        // this single-flight rather than merely cached.
        if let inFlight { return try await inFlight.value }

        let task = Task { try await load() }
        inFlight = task
        // Cleared on the way out however this ends. A failure left in the
        // slot would be permanent: every later caller would join a task that
        // has already thrown, so re-downloading from Settings could never
        // recover, because nothing would ever attempt a load again.
        defer { inFlight = nil }

        let result = try await task.value
        loaded = result
        return result
    }
}
