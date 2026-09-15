import AppKit

/// How complete our copy of the user's clipboard is.
///
/// Three states, not two. An earlier version asked only "did we save
/// anything", read an empty array as *"the clipboard was empty to begin
/// with"*, cleared the pasteboard and reported success — a 40 MB TIFF went in
/// and an empty pasteboard came out. An empty array is not a fact about the
/// clipboard, it is a fact about our copy of it.
public enum Fidelity: Equatable, Sendable {
    /// No snapshot has been taken yet.
    case notTaken
    /// Everything on the pasteboard is in hand. Includes the genuinely empty
    /// clipboard, which correctly restores to empty.
    case faithful
    /// Real bytes were dropped and cannot be put back.
    case lossy
}

/// Borrows the general pasteboard and gives it back.
public final class PasteboardTransaction {
    private let pasteboard: NSPasteboard
    private var saved: [[(type: NSPasteboard.PasteboardType, data: Data)]] = []

    public private(set) var fidelity: Fidelity = .notTaken

    private var expectedChangeCount: Int?
    private var holdsBorrow = false

    /// Checked by callers *before* anything writes. Once a keystroke has been
    /// posted or a scratch write made, the user's bytes are already gone.
    public var canBorrow: Bool { fidelity == .faithful }

    private let borrow: PasteboardBorrow

    /// The registry is injected so a test suite can own its own and stay
    /// hermetic. Production always uses the shared one: the exclusion has to
    /// be process-wide to mean anything.
    public init(pasteboard: NSPasteboard, borrow: PasteboardBorrow = .shared) {
        self.pasteboard = pasteboard
        self.borrow = borrow
    }

    /// A copied screenshot or video frame can be hundreds of megabytes, and
    /// duplicating that for a two-second round trip is more cost than a
    /// rewrite is worth.
    public static let snapshotByteBudget = 16 * 1024 * 1024

    /// Asking for the bytes of every declared type also forces lazy promise
    /// providers to deliver, which is a deliberate cost: a promise we did not
    /// resolve is a promise we cannot put back.
    ///
    /// Returns false when the clipboard cannot be borrowed. Callers must
    /// honour that *before* writing anything.
    @discardableResult
    public func snapshot() -> Bool {
        // Exclusive, before a single byte is read. `notTaken` is the honest
        // answer: no snapshot exists, and none was lost either.
        guard borrow.acquire(pasteboard.name) else {
            fidelity = .notTaken
            return false
        }
        holdsBorrow = true

        var budgetRemaining = Self.snapshotByteBudget
        var collected: [[(type: NSPasteboard.PasteboardType, data: Data)]] = []

        for item in pasteboard.pasteboardItems ?? [] {
            // An ordered array rather than a dictionary: pasteboard type order
            // is preference order, and the first type a reader recognises is
            // the one it uses, so reordering demotes rich text below plain.
            var fields: [(type: NSPasteboard.PasteboardType, data: Data)] = []
            for type in item.types {
                // No bytes of its own: a flavour AppKit derives on demand, and
                // the same machinery re-advertises it once the base types are
                // restored. Nothing is lost, so this is not lossiness.
                guard let data = item.data(forType: type) else { continue }

                guard data.count <= budgetRemaining else {
                    // Refuse the whole borrow rather than restoring a partial
                    // clipboard, which would be a silent downgrade the user
                    // has no way to notice.
                    saved = []
                    expectedChangeCount = nil
                    fidelity = .lossy
                    releaseBorrow()
                    return false
                }
                budgetRemaining -= data.count
                fields.append((type: type, data: data))
            }
            collected.append(fields)
        }

        saved = collected
        expectedChangeCount = pasteboard.changeCount
        fidelity = .faithful
        return true
    }

    /// Our own scratch write, during a paste.
    public func writeTransient(_ text: String) {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        // The nspasteboard.org convention every mainstream macOS clipboard
        // manager honours. Without these, every rewrite leaves a junk entry in
        // the user's clipboard history. The markers ride on the same item as
        // the text so they show up in `NSPasteboard.types`, which is where
        // managers look.
        //
        // `org.nspasteboard.ConcealedType` is deliberately not set: it means
        // "this is a password" and some managers warn on it. Transient already
        // prevents recording, so the stronger claim would be a misuse of the
        // convention for no additional benefit.
        item.setString("", forType: .init("org.nspasteboard.TransientType"))
        item.setString("", forType: .init("org.nspasteboard.AutoGeneratedType"))

        expectedChangeCount = pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }

    /// The copy-only outcome: the user is expected to paste this themselves,
    /// so it has to survive. Still the opposite of the scratch write above and
    /// the two must not be merged — that one is *always* transient and this
    /// one is restored away by nobody.
    ///
    /// **This used to be unconditionally unmarked, and that was deliberate**:
    /// the argument was that a manager should record something the user is
    /// about to paste by hand. The setting reverses it, because a rewrite is
    /// not something they copied and most people do not want their history
    /// filled with them — and the reversal is safe only because the markers
    /// stop *recording*, not pasting. Changed here rather than left standing,
    /// so the next reader does not restore the old behaviour as a bug fix.
    public func writeDurable(_ text: String, keepOutOfHistory: Bool) {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)

        // The markers stop a manager *recording* the item; they do not stop
        // ⌘V. That is what makes "keep rewrites out of history" safe as a
        // default here: `copiedOnly` promises the text is on the clipboard
        // for the user to paste, and a transient item still is.
        //
        // Both markers, because managers differ in which they honour and
        // both are true of a rewrite. Never `ConcealedType` — the convention
        // reserves that for passwords and some managers warn on it.
        if keepOutOfHistory {
            item.setString("", forType: .init("org.nspasteboard.TransientType"))
            item.setString("", forType: .init("org.nspasteboard.AutoGeneratedType"))
        }

        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        // Terminal: this path never restores, so the borrow ends here.
        releaseBorrow()
    }

    /// Ends the transaction without writing: nothing happened, so there is
    /// nothing to put back. Separate from `restoreIfUnchanged` because that
    /// one always writes, and writing the same bytes back over an untouched
    /// clipboard bumps the change count and leaves a duplicate entry in the
    /// user's clipboard history for a rewrite that never started.
    public func abandon() {
        releaseBorrow()
    }

    /// Declares which change count the transaction should treat as its own,
    /// for the case where the writer was the *target app* answering a
    /// synthetic ⌘C rather than us.
    public func expect(changeCount: Int) {
        expectedChangeCount = changeCount
    }

    /// Puts the user's own content back, written plain with no markers: that
    /// content is theirs, a manager that missed the original should be able to
    /// record it, and a duplicate history entry is a far smaller harm than a
    /// manager showing our scratch text as the user's current clipboard.
    @discardableResult
    public func restoreIfUnchanged() -> Bool {
        // Refuse outright on anything but a faithful snapshot and leave the
        // pasteboard alone. This is a backstop for a caller who forgets the
        // `canBorrow` check, not the mechanism: by the time we are here the
        // user's bytes are already gone from our copy.
        guard fidelity == .faithful else { return false }

        // Gated on the change count still being exactly what our step left it
        // at. If anything at all has written since, the user's content is
        // newer than ours and we leave it alone.
        //
        // Declining is still a logical end, so the borrow ends here too.
        // Without that, `pasteReplace`'s `handOff` on the very next line
        // cannot acquire and tells the user another rewrite is using the
        // clipboard — false, and it withholds the rewrite instead of copying
        // it for them.
        guard pasteboard.changeCount == expectedChangeCount else {
            releaseBorrow()
            return false
        }

        pasteboard.clearContents()
        let items = saved.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for field in entry { item.setData(field.data, forType: field.type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
        releaseBorrow()
        return true
    }

    /// Released at every *logical* end of the transaction, never left to
    /// deallocation. Tying a process-wide lock to `deinit` means the borrow
    /// outlives the work by however long ARC takes, and AppKit recycles a
    /// released pasteboard's name, so the next borrower can collide with a
    /// transaction that finished long ago. `deinit` is a backstop only.
    private func releaseBorrow() {
        guard holdsBorrow else { return }
        holdsBorrow = false
        borrow.release(pasteboard.name)
    }

    deinit { releaseBorrow() }
}
