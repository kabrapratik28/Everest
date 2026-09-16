import os
import Testing

@testable import Engines

/// **Swift actors are reentrant across `await`.** That one fact is the whole
/// of this suite.
///
/// `LoadedModel` used to be an actor holding `if let container { return it }`,
/// `await loadContainer(…)`, `container = loaded`, with a comment saying the
/// actor was what stopped two hotkey presses starting two loads of the same
/// 2.3 GB model. It stopped nothing: the `await` releases the actor, the
/// second caller walks in, sees `nil`, and starts its own load. On the 30 GB
/// option that is two 17.2 GB loads resident at once.
///
/// Mutual exclusion is not serialisation of a *sequence*. An actor gives you
/// one-at-a-time access to its state, never a promise that a check and the
/// write it guards are not separated by somebody else's turn.
@Suite("LoadOnce")
struct LoadOnceTests {
    /// The defect, directly. Eight callers arrive while the first load is
    /// still in flight; exactly one load may happen.
    ///
    /// Eight rather than two because the failure is a race and one pair can
    /// interleave innocently. Against the old implementation every one of the
    /// eight starts its own load, so the count is the population size and the
    /// result is unambiguous.
    @Test("callers arriving during a load join it instead of starting another")
    func concurrentCallersShareOneLoad() async throws {
        let loader = LoadOnce<Int>()
        let loads = OSAllocatedUnfairLock(initialState: 0)

        let results = await withTaskGroup(of: Int?.self) { group in
            for _ in 0 ..< 8 {
                group.addTask {
                    try? await loader.value {
                        loads.withLock { $0 += 1 }
                        // Held open long enough that every caller is inside
                        // `value(_:)` before the first one finishes. Without
                        // the suspension there is no window to test.
                        try await Task.sleep(for: .milliseconds(50))
                        return 42
                    }
                }
            }
            return await group.reduce(into: [Int?]()) { $0.append($1) }
        }

        #expect(loads.withLock { $0 } == 1, "one load, however many callers ask at once")
        #expect(results.allSatisfy { $0 == 42 }, "every caller gets the loaded value")
    }

    /// The value is kept, so a later caller does not reload it. This is the
    /// half the old code got right, asserted so a fix for the race above
    /// cannot quietly drop it — retrying the load on every request would also
    /// make the race test pass.
    @Test("a loaded value is reused by later callers")
    func aLoadedValueIsReused() async throws {
        let loader = LoadOnce<Int>()
        let loads = OSAllocatedUnfairLock(initialState: 0)
        let body: @Sendable () async throws -> Int = {
            loads.withLock { $0 += 1 }
            return 7
        }

        #expect(try await loader.value(body) == 7)
        #expect(try await loader.value(body) == 7)
        #expect(loads.withLock { $0 } == 1)
    }

    /// A load that threw must not be remembered as one in progress.
    ///
    /// Otherwise the first failure — a truncated safetensors file, a model
    /// evicted mid-load — is permanent for the life of the process: every
    /// later attempt joins a task that has already failed, and the only
    /// remedy the app offers, re-downloading from Settings, cannot help
    /// because nothing ever tries to load again.
    @Test("a failed load is not cached, and the next caller retries")
    func aFailedLoadIsRetried() async throws {
        let loader = LoadOnce<Int>()
        let loads = OSAllocatedUnfairLock(initialState: 0)

        await #expect(throws: LoadFailure.self) {
            try await loader.value {
                loads.withLock { $0 += 1 }
                throw LoadFailure.unloadable
            }
        }
        #expect(await loader.existing == nil, "a failure is not a value")

        let recovered = try await loader.value {
            loads.withLock { $0 += 1 }
            return 99
        }

        #expect(recovered == 99)
        #expect(loads.withLock { $0 } == 2, "the second attempt ran rather than joining the first")
    }

    /// `existing` answers from what is already there and never starts a load.
    /// `MLXTokenProducer` asks it to turn "generate before prepare" into
    /// `modelNotLoaded` rather than a surprise multi-second stall.
    @Test("existing reports nothing before anything is loaded")
    func existingIsNilBeforeAnyLoad() async {
        #expect(await LoadOnce<Int>().existing == nil)
    }
}

private enum LoadFailure: Error { case unloadable }
