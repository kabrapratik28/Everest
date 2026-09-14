import AppKit
import CoreGraphics
import OSLog

private let log = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Everest",
    category: "selection.clipboard"
)

/// Posts a Command key chord as if the user had typed it.
///
/// Lives here rather than in its own file because synthesising Command C is
/// exactly what the clipboard capture path is. `ReplacementService` reuses it
/// for Command V.
@MainActor
enum SyntheticKeystroke {

    /// ANSI virtual key codes. The `kVK_ANSI_*` constants from Carbon are not
    /// compile time constants in Swift, so the two we need are spelled out.
    enum Key: CGKeyCode {
        case c = 0x08  // kVK_ANSI_C
        case v = 0x09  // kVK_ANSI_V
    }

    /// Sends Command plus `key` to whatever is frontmost.
    ///
    /// Three details that are easy to get wrong:
    ///
    /// The flags are set explicitly instead of posting separate modifier key
    /// events. Everest is triggered by a Command chord, so the user is very
    /// likely still physically holding Command when this runs. Posting a
    /// synthetic Command-up would clear the system's idea of a key the user is
    /// still pressing and leave the keyboard in a state they did not ask for.
    /// Setting `flags` on the character event alone avoids touching modifier
    /// state at all.
    ///
    /// The event suppression filter is relaxed. After any synthetic event the
    /// window server suppresses *real* local input for a quarter of a second by
    /// default. Left alone, that means every rewrite silently eats whatever the
    /// user typed in the moment right afterwards.
    ///
    /// The event goes to the HID tap, the lowest point in the chain, because
    /// apps that install their own event taps (most Electron apps, anything
    /// with a custom shortcut layer) only see events that pass through it.
    static func postCommand(_ key: Key) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let permitted: CGEventFilterMask = [
            .permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents,
        ]
        source?.setLocalEventsFilterDuringSuppressionState(
            permitted, state: .eventSuppressionStateSuppressionInterval)
        source?.setLocalEventsFilterDuringSuppressionState(
            permitted, state: .eventSuppressionStateRemoteMouseDrag)

        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key.rawValue, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key.rawValue, keyDown: false)
        else {
            log.error("could not build synthetic key event")
            return
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

/// Last resort capture: ask the frontmost app to copy, and read what it copied.
///
/// This exists for apps that expose nothing useful over accessibility: some
/// Java and Qt toolkits, terminal emulators with custom text layers, and older
/// cross-platform editors. It is last in the chain for three reasons. It is the
/// only path that disturbs the user's clipboard. It is the only path that
/// depends on the target having a working Edit > Copy. And it leaves the
/// selected text in any clipboard history app the user runs, which no amount of
/// care on our side can prevent, because the *target app* is the one writing.
/// Not `final`, on purpose. The guard tests substitute a subclass that records
/// whether `copySelection()` was reached, which is how "a secure field is
/// refused before any text is read" is asserted rather than merely described.
/// A stub is also the only way to test that path without posting a real
/// Command C into whatever app the developer happens to have in front.
@MainActor
class ClipboardSelectionAdapter {

    /// How long to wait for the target to answer the synthetic copy.
    static let copyBudget: TimeInterval = 0.40

    /// After the change count moves, how long to keep waiting for readable
    /// text. An app clears the pasteboard and writes it in two steps, so there
    /// is a window in which the count has already moved and the data has not
    /// landed.
    static let settleBudget: TimeInterval = 0.12

    /// Poll granularity. Small enough that a fast app costs about ten
    /// milliseconds, large enough not to spin.
    static let pollInterval: TimeInterval = 0.008

    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    /// Returns the text the target copied, or `nil` if it copied nothing.
    ///
    /// The single most important property of this method: it reads the
    /// pasteboard **only after observing the change count move**. If the user
    /// has nothing selected, Command C is a no-op, the change count does not
    /// move, and we return `nil`. Reading the pasteboard unconditionally would
    /// hand back whatever the user happened to have copied earlier, and Everest
    /// would cheerfully rewrite an unrelated paragraph, a password, or a URL
    /// the user was about to paste. That bug is silent and looks like the app
    /// hallucinating.
    ///
    /// The user's clipboard is put back before returning, so the selected text
    /// does not linger there.
    func copySelection() -> String? {
        let transaction = PasteboardTransaction(pasteboard: pasteboard)

        // Before the keystroke, not after. The synthetic Command C makes the
        // *target app* overwrite the pasteboard, so if we cannot put the user's
        // clipboard back afterwards we must not provoke that write at all. A
        // rewrite that does not happen is a fine outcome; a destroyed image is
        // not, and it is not recoverable once the app has written.
        guard transaction.snapshot() else {
            log.info("clipboard capture skipped: the current clipboard cannot be saved and restored")
            return nil
        }

        let before = pasteboard.changeCount
        SyntheticKeystroke.postCommand(.c)

        guard waitForChangeCount(toDifferFrom: before, budget: Self.copyBudget) else {
            log.debug("synthetic copy produced no pasteboard change")
            transaction.abandon()
            return nil
        }

        guard let landed = waitForStableString(budget: Self.settleBudget) else {
            // Either the target copied something that is not text, or a write
            // landed while we were reading and we cannot say whose it was.
            // Both mean: take nothing, and do not touch their clipboard.
            transaction.abandon()
            return nil
        }

        // Adopt the count observed at the same instant as the text, not a
        // fresh read. A user copy landing between the two reads would
        // otherwise be adopted as ours and then overwritten by the restore.
        transaction.expect(changeCount: landed.changeCount)
        transaction.restoreIfUnchanged()

        let text: String? = landed.text
        guard let text, !text.isEmpty else { return nil }
        log.debug("clipboard capture: \(text.count, privacy: .public) characters")
        return text
    }

    // MARK: - Bounded waits

    /// Blocks the main thread in short slices.
    ///
    /// Blocking is acceptable here and a nested run loop is not. `capture()` is
    /// synchronous by design, and pumping the run loop from inside a hotkey
    /// handler would let a second hotkey press re-enter the capture chain while
    /// the first is halfway through borrowing the clipboard. The worst case is
    /// four hundred milliseconds on a path that only accessibility-hostile apps
    /// reach.
    private func waitForChangeCount(toDifferFrom original: Int, budget: TimeInterval) -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(budget))
        while ContinuousClock.now < deadline {
            if pasteboard.changeCount != original { return true }
            Thread.sleep(forTimeInterval: Self.pollInterval)
        }
        return pasteboard.changeCount != original
    }

    /// Reads the pasteboard text together with the change count it belongs to.
    ///
    /// The two are read as a sandwich, count then text then count again, and
    /// the result is only returned when both counts agree. Reading them
    /// separately leaves a gap: a user copy landing inside it would either be
    /// mistaken for the selection we asked for, or be adopted as our own change
    /// count and then overwritten by the restore. The sandwich turns that race
    /// into a clean "we do not know", which costs one capture and destroys
    /// nothing.
    private func waitForStableString(budget: TimeInterval) -> (text: String?, changeCount: Int)? {
        let deadline = ContinuousClock.now.advanced(by: .seconds(budget))
        while ContinuousClock.now < deadline {
            let before = pasteboard.changeCount
            if let text = pasteboard.string(forType: .string) {
                guard pasteboard.changeCount == before else { return nil }
                return (text, before)
            }
            Thread.sleep(forTimeInterval: Self.pollInterval)
        }
        // Budget spent. Not a failure in itself: the user may have selected an
        // image or a file, in which case the target copied something real that
        // is not text, and we still need a change count so the restore can run.
        let before = pasteboard.changeCount
        let text = pasteboard.string(forType: .string)
        guard pasteboard.changeCount == before else { return nil }
        return (text, before)
    }
}
