import Foundation
import os

/// Holds the one in-flight generation task so it can be stopped.
///
/// **A lock, not an actor, and that is load-bearing.** The task is registered
/// synchronously inside the `AsyncThrowingStream` initializer, before
/// `stream(_:)` returns to its caller. An earlier implementation hopped to an
/// actor to record it, which left a window where a caller doing `stream()` and
/// then `cancel()` on the very next line found nothing registered and left the
/// generation running to completion.
final class TransactionBox: Sendable {
    private let current = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    /// Registers `task` as the in-flight generation, cancelling whatever it
    /// replaced. A second hotkey press must not leave two streams racing to
    /// fill the same panel.
    func begin(_ task: Task<Void, Never>) {
        let replaced = current.withLock { slot in
            let previous = slot
            slot = task
            return previous
        }
        replaced?.cancel()
    }

    /// Stops the in-flight generation.
    ///
    /// This cancels the `Task` rather than merely discarding its output,
    /// because mlx-swift-lm's decode loop is `while !Task.isCancelled` and
    /// checks between every token. Dropping the result instead would leave
    /// the GPU decoding several hundred tokens for a panel that is already
    /// gone, which on the 30B option is seconds of a stalled machine.
    func cancel() {
        let task = current.withLock { slot in
            let task = slot
            slot = nil
            return task
        }
        task?.cancel()
    }
}
