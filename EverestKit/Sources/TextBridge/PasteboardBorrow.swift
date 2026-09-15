import AppKit

/// Makes borrowing a given pasteboard exclusive across the process.
///
/// The `changeCount` guard protects against *other* writers. Under
/// re-entrancy the other writer is us, and it cannot help: a second rewrite
/// starting while the first sits between `writeTransient` and
/// `restoreIfUnchanged` snapshots our own scratch text as if it were the
/// user's clipboard, then restores that. Every change-count check passes,
/// because from each transaction's point of view nothing went wrong, and the
/// user's real clipboard is gone.
///
/// Blocking the main thread makes that unreachable today, but that is a fact
/// about scheduling rather than about correctness, and it evaporates the
/// moment somebody adds a suspension point to silence the 450 ms hitch. The
/// exclusion is therefore enforced here, at the point that would nest, so
/// the change-count guard is sound rather than merely usually-true.
///
/// Keyed by pasteboard name, so two different pasteboards never contend.
/// Refused rather than queued: both transactions run on the main thread, so
/// waiting would stop the holder from ever finishing and releasing.
public final class PasteboardBorrow: @unchecked Sendable {
    public static let shared = PasteboardBorrow()

    public init() {}

    private let lock = NSLock()
    private var held: Set<NSPasteboard.Name> = []

    func acquire(_ name: NSPasteboard.Name) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return held.insert(name).inserted
    }

    func release(_ name: NSPasteboard.Name) {
        lock.lock()
        defer { lock.unlock() }
        held.remove(name)
    }
}
