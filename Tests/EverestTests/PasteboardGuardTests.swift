import AppKit
import XCTest

@testable import Everest

/// Guards from root `AGENTS.md` section 5:
///
/// - "Conditional pasteboard restore on `changeCount`: anything the user
///   copies during a rewrite is silently destroyed."
/// - The oversize-clipboard case behind the Critical review finding, where a
///   40 MB image was wiped and the restore reported success.
///
/// Everything here runs against a private `NSPasteboard`. A test that touched
/// `NSPasteboard.general` would destroy the clipboard of whoever is using the
/// machine, which is the exact harm the code under test exists to prevent.
@MainActor
final class PasteboardGuardTests: XCTestCase {

    private var pasteboard: NSPasteboard!

    override func setUp() {
        super.setUp()
        pasteboard = makePrivatePasteboard("pasteboard-guards")
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        pasteboard = nil
        super.tearDown()
    }

    // MARK: - The Critical regression

    /// An oversize clipboard must be left exactly as it was found.
    ///
    /// This is the most valuable test in the bundle. The bug it pins: the
    /// snapshot dropped every payload for exceeding the 16 MB budget, `saved`
    /// came out empty, `restoreIfUnchanged` read that as "the clipboard was
    /// empty to begin with", cleared the pasteboard and returned `true`. A
    /// 40 MB image went in and nothing came out, with no signal anywhere.
    ///
    /// If someone collapses `Fidelity` back into a boolean, or moves the
    /// completeness check from `snapshot()` to the restore, this fails.
    func testOversizeClipboardIsNeverDestroyed() {
        let payload = Data(count: 40 * 1024 * 1024)
        let item = NSPasteboardItem()
        item.setData(payload, forType: .tiff)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([item]))
        let changeCountBefore = pasteboard.changeCount

        let transaction = PasteboardTransaction(pasteboard: pasteboard)

        XCTAssertFalse(
            transaction.snapshot(),
            "snapshot() must report that a clipboard it cannot hold may not be borrowed")
        XCTAssertEqual(transaction.fidelity, .lossy)
        XCTAssertFalse(transaction.canBorrow)

        // The old bug returned true here, having just cleared the pasteboard.
        XCTAssertFalse(
            transaction.restoreIfUnchanged(),
            "a lossy transaction must refuse to restore rather than clear and claim success")

        XCTAssertEqual(pasteboard.pasteboardItems?.count, 1, "the user's item must still be there")
        XCTAssertEqual(
            pasteboard.pasteboardItems?.first?.data(forType: .tiff)?.count,
            40 * 1024 * 1024,
            "every byte of the user's clipboard must survive")
        XCTAssertEqual(
            pasteboard.changeCount, changeCountBefore,
            "nothing may write to a pasteboard we cannot put back")
    }

    /// The capture path must abort before the keystroke, not after.
    ///
    /// A synthetic Command C makes the *target app* overwrite the pasteboard.
    /// Once that has happened there is no way back, so the decision has to be
    /// taken before the keystroke is posted. Asserting the change count never
    /// moved is what proves no write was provoked.
    func testClipboardCaptureDeclinesWhenTheClipboardCannotBeSaved() {
        let item = NSPasteboardItem()
        item.setData(Data(count: 40 * 1024 * 1024), forType: .tiff)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([item]))
        let changeCountBefore = pasteboard.changeCount

        let adapter = ClipboardSelectionAdapter(pasteboard: pasteboard)
        XCTAssertNil(adapter.copySelection(), "capture must decline rather than risk the clipboard")

        XCTAssertEqual(
            pasteboard.pasteboardItems?.first?.data(forType: .tiff)?.count, 40 * 1024 * 1024)
        XCTAssertEqual(
            pasteboard.changeCount, changeCountBefore,
            "declining must not itself disturb the pasteboard")
    }

    /// The guard must not pass by simply switching the feature off. A payload
    /// under the budget still has to round-trip.
    func testAffordableClipboardStillRoundTrips() {
        let payload = Data(repeating: 0xAB, count: 1024 * 1024)
        let item = NSPasteboardItem()
        item.setData(payload, forType: .tiff)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([item]))

        let transaction = PasteboardTransaction(pasteboard: pasteboard)
        XCTAssertTrue(transaction.snapshot())
        XCTAssertEqual(transaction.fidelity, .faithful)

        transaction.writeTransient("scratch")
        XCTAssertTrue(transaction.restoreIfUnchanged())
        XCTAssertEqual(pasteboard.pasteboardItems?.first?.data(forType: .tiff), payload)
    }

    // MARK: - Multi-type round trip

    /// Restoring only `.string` would silently downgrade a copied table to a
    /// line of tab separated words. Every declared type and its order have to
    /// come back.
    func testEveryTypeAndItemOrderSurvivesTheRoundTrip() {
        let rtf = Data([0x7B, 0x5C, 0x72, 0x74, 0x66, 0x31])
        let png = Data([0x89, 0x50, 0x4E, 0x47])

        let first = NSPasteboardItem()
        first.setString("plain one", forType: .string)
        first.setData(rtf, forType: .rtf)
        first.setData(png, forType: .png)
        let second = NSPasteboardItem()
        second.setString("plain two", forType: .string)

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([first, second]))
        let typesBefore = (pasteboard.pasteboardItems ?? []).map { $0.types }

        let transaction = PasteboardTransaction(pasteboard: pasteboard)
        XCTAssertTrue(transaction.snapshot())
        transaction.writeTransient("scratch rewrite")
        XCTAssertEqual(pasteboard.string(forType: .string), "scratch rewrite")
        XCTAssertTrue(transaction.restoreIfUnchanged())

        let typesAfter = (pasteboard.pasteboardItems ?? []).map { $0.types }
        XCTAssertEqual(typesAfter, typesBefore, "type order is preference order and must survive")
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 2)
        XCTAssertEqual(pasteboard.pasteboardItems?[0].data(forType: .rtf), rtf)
        XCTAssertEqual(pasteboard.pasteboardItems?[0].data(forType: .png), png)
        XCTAssertEqual(pasteboard.pasteboardItems?[1].string(forType: .string), "plain two")
    }

    /// Our scratch write must be invisible to clipboard history apps, and the
    /// restored content must not be, because that content is the user's own.
    func testScratchWriteIsMarkedAndTheRestoreIsNot() {
        pasteboard.clearContents()
        pasteboard.setString("user content", forType: .string)

        let transaction = PasteboardTransaction(pasteboard: pasteboard)
        XCTAssertTrue(transaction.snapshot())
        transaction.writeTransient("scratch")

        XCTAssertEqual(pasteboard.types?.contains(.nsTransient), true)
        XCTAssertEqual(pasteboard.types?.contains(.nsAutoGenerated), true)

        XCTAssertTrue(transaction.restoreIfUnchanged())
        XCTAssertNotEqual(pasteboard.types?.contains(.nsTransient), true)
        XCTAssertNotEqual(pasteboard.types?.contains(.nsAutoGenerated), true)
        XCTAssertEqual(pasteboard.string(forType: .string), "user content")
    }

    // MARK: - The conditional restore

    /// The guard root `AGENTS.md` section 5 describes as "anything the user
    /// copies during a rewrite is silently destroyed".
    ///
    /// A write landing mid-transaction stands for the user pressing Command C
    /// in another window. Their content is newer than ours, so the restore
    /// must decline and leave it alone. Replacing the `changeCount` check with
    /// any delay, however short, fails this.
    func testRestoreDeclinesWhenSomethingElseWroteDuringTheTransaction() {
        pasteboard.clearContents()
        pasteboard.setString("original user content", forType: .string)

        let transaction = PasteboardTransaction(pasteboard: pasteboard)
        XCTAssertTrue(transaction.snapshot())
        transaction.writeTransient("scratch rewrite")

        // The user copies something else while the rewrite is generating.
        pasteboard.clearContents()
        pasteboard.setString("WHAT THE USER JUST COPIED", forType: .string)

        XCTAssertFalse(
            transaction.restoreIfUnchanged(),
            "a restore must never run over a pasteboard somebody else has written")
        XCTAssertEqual(
            pasteboard.string(forType: .string), "WHAT THE USER JUST COPIED",
            "the user's newer content must survive untouched")
    }

    /// The mirror image: with nothing else writing, the restore must actually
    /// happen. Otherwise the previous test could pass by never restoring.
    func testRestoreHappensWhenNothingElseWrote() {
        pasteboard.clearContents()
        pasteboard.setString("original user content", forType: .string)

        let transaction = PasteboardTransaction(pasteboard: pasteboard)
        XCTAssertTrue(transaction.snapshot())
        transaction.writeTransient("scratch rewrite")
        XCTAssertTrue(transaction.restoreIfUnchanged())
        XCTAssertEqual(pasteboard.string(forType: .string), "original user content")
    }

    /// A genuinely empty clipboard is a faithful snapshot and restores to
    /// empty. This is the state the Critical bug confused with "we could not
    /// save it", so the two must stay distinguishable.
    func testGenuinelyEmptyClipboardIsFaithfulAndRestoresToEmpty() {
        pasteboard.clearContents()

        let transaction = PasteboardTransaction(pasteboard: pasteboard)
        XCTAssertTrue(transaction.snapshot())
        XCTAssertEqual(transaction.fidelity, .faithful, "empty is not the same as unsavable")

        transaction.writeTransient("scratch")
        XCTAssertTrue(transaction.restoreIfUnchanged())
        XCTAssertTrue((pasteboard.pasteboardItems ?? []).isEmpty)
    }

    /// `abandon` is how a `.copiedOnly` outcome deliberately leaves our text
    /// in place. It must not restore, and a later restore must be a no-op.
    func testAbandonLeavesOurTextAndBlocksLaterRestores() {
        pasteboard.clearContents()
        pasteboard.setString("user content", forType: .string)

        let transaction = PasteboardTransaction(pasteboard: pasteboard)
        XCTAssertTrue(transaction.snapshot())
        transaction.writeTransient("kept for the user")
        transaction.abandon()

        XCTAssertEqual(pasteboard.string(forType: .string), "kept for the user")
        XCTAssertFalse(transaction.restoreIfUnchanged())
        XCTAssertEqual(pasteboard.string(forType: .string), "kept for the user")
    }

    /// Byte-exact preservation, on the clipboard side. Whitespace, tabs, a
    /// newline, a zero-width space, a combining accent and an emoji cluster
    /// all have to come back identical.
    func testAwkwardTextSurvivesByteForByte() {
        let awkward = "  leading and trailing  \n\ttabbed\r\nCRLF \u{200B}zw e\u{0301} \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} "
        pasteboard.clearContents()
        pasteboard.setString(awkward, forType: .string)

        let transaction = PasteboardTransaction(pasteboard: pasteboard)
        XCTAssertTrue(transaction.snapshot())
        transaction.writeTransient("x")
        XCTAssertTrue(transaction.restoreIfUnchanged())
        XCTAssertEqual(pasteboard.string(forType: .string), awkward)
    }

    /// A derived flavour that cannot render, such as
    /// `public.utf16-external-plain-text` behind malformed RTF, has no bytes
    /// to lose and must not be mistaken for a lossy snapshot. An earlier
    /// version of this flag cried wolf on every rich clipboard.
    func testUnrenderableDerivedTypeDoesNotMakeASnapshotLossy() {
        let item = NSPasteboardItem()
        item.setString("plain", forType: .string)
        item.setData(Data([0x7B, 0x5C, 0x72, 0x74]), forType: .rtf)  // deliberately malformed
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([item]))

        let transaction = PasteboardTransaction(pasteboard: pasteboard)
        XCTAssertTrue(transaction.snapshot())
        XCTAssertEqual(transaction.fidelity, .faithful)
    }
}
