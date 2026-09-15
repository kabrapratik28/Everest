import AppKit
import Testing

@testable import TextBridge

/// Every test here uses a uniquely-named private pasteboard and releases it
/// afterwards. `NSPasteboard.general` is never touched, so the suite is safe
/// to run while the user is working.
@Suite("Pasteboard transaction")
struct PasteboardTransactionTests {

    private func withPrivatePasteboard(_ body: (NSPasteboard) throws -> Void) rethrows {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try body(pasteboard)
    }

    private let rtf = Data("{\\rtf1\\ansi some rich text}".utf8)
    private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 4])
    private let secret = Data("private payload".utf8)
    private let customType = NSPasteboard.PasteboardType("com.example.private")

    private func richItem(plain: String) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        // Declared richest-first: pasteboard type order is preference order,
        // and the first type a reader recognises is the one it uses.
        item.setData(rtf, forType: .rtf)
        item.setData(png, forType: .png)
        item.setData(secret, forType: customType)
        item.setString(plain, forType: .string)
        return item
    }

    /// Reading only `.string` is the easy version and it is wrong. A clipboard
    /// routinely carries the same content as RTF, HTML, PNG, a file URL and
    /// plain text at once, and restoring only the plain text silently
    /// downgrades a copied table to a line of tab-separated words with no way
    /// for the user to know Everest did it.
    @Test("a snapshot round-trips every declared type on every item, in order")
    func snapshotRoundTripsAllDeclaredTypes() throws {
        withPrivatePasteboard { pasteboard in
            pasteboard.clearContents()
            pasteboard.writeObjects([richItem(plain: "first"), richItem(plain: "second")])
            let declared = pasteboard.pasteboardItems!.map(\.types)

            let transaction = PasteboardTransaction(pasteboard: pasteboard)
            #expect(transaction.snapshot())
            #expect(transaction.fidelity == .faithful)

            transaction.writeTransient("scratch")
            #expect(pasteboard.string(forType: .string) == "scratch")

            #expect(transaction.restoreIfUnchanged())

            let restored = pasteboard.pasteboardItems!
            #expect(restored.count == 2)
            #expect(restored.map(\.types) == declared, "type order is preference order")
            for (index, item) in restored.enumerated() {
                #expect(item.data(forType: .rtf) == rtf)
                #expect(item.data(forType: .png) == png)
                #expect(item.data(forType: customType) == secret)
                #expect(item.string(forType: .string) == (index == 0 ? "first" : "second"))
            }
        }
    }

    /// The obvious implementation restores after a short delay, and a delay
    /// races the user and silently eats whatever they copied. There is no
    /// delay short enough to win the race and none long enough to be safe,
    /// because the hazard is a user action rather than a duration.
    @Test("restore declines when something else wrote to the pasteboard mid-transaction")
    func restoreDeclinesWhenChangeCountMoved() throws {
        withPrivatePasteboard { pasteboard in
            pasteboard.clearContents()
            pasteboard.setString("the user's original", forType: .string)

            let transaction = PasteboardTransaction(pasteboard: pasteboard)
            #expect(transaction.snapshot())
            transaction.writeTransient("scratch")

            // The user presses ⌘C in another window while the rewrite runs.
            pasteboard.clearContents()
            pasteboard.setString("what the user just copied", forType: .string)

            #expect(transaction.restoreIfUnchanged() == false)
            #expect(
                pasteboard.string(forType: .string) == "what the user just copied",
                "their content is newer than ours, so we leave it alone"
            )
        }
    }

    /// Resolves a promise when asked, and lets something else write the
    /// pasteboard first. That is the real window: `data(forType:)` forces a
    /// lazy provider to deliver, and a provider is exactly where the read
    /// takes long enough for another process to get in.
    private final class SlowProvider: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
        let onResolve: @Sendable () -> Void
        init(onResolve: @escaping @Sendable () -> Void) { self.onResolve = onResolve }

        func pasteboard(
            _ pasteboard: NSPasteboard?, item: NSPasteboardItem,
            provideDataForType type: NSPasteboard.PasteboardType
        ) {
            onResolve()
            item.setData(Data("resolved".utf8), forType: type)
        }
    }

    /// The count was recorded *after* materialising, so a write landing
    /// during the read got blessed as ours: we would later clear the newer
    /// clipboard and restore the bytes we had read before it arrived.
    ///
    /// Refusing is the only safe answer — by the time we notice, what we hold
    /// is a mixture of two clipboards and we cannot tell which parts.
    @Test("a clipboard that changes while it is being read is not snapshotted")
    func aClipboardWrittenDuringTheReadIsRefused() throws {
        withPrivatePasteboard { pasteboard in
            nonisolated(unsafe) let board = pasteboard
            let provider = SlowProvider {
                // Another process copies while our promise resolves.
                board.clearContents()
                board.setString("what the user just copied", forType: .string)
            }
            let item = NSPasteboardItem()
            item.setDataProvider(provider, forTypes: [.tiff])
            pasteboard.clearContents()
            pasteboard.writeObjects([item])

            let transaction = PasteboardTransaction(pasteboard: pasteboard)

            #expect(transaction.snapshot() == false, "the bytes we hold span two clipboards")
            #expect(transaction.canBorrow == false)
            #expect(
                pasteboard.string(forType: .string) == "what the user just copied",
                "and their newer content is left exactly alone")
        }
    }

    /// A promise whose provider cannot deliver. `data(forType:)` then
    /// returns nil for that type — and, measured, for derivable flavours
    /// alongside it whose content is sitting in the same item.
    private final class RefusingProvider: NSObject, NSPasteboardItemDataProvider,
        @unchecked Sendable
    {
        func pasteboard(
            _ pasteboard: NSPasteboard?, item: NSPasteboardItem,
            provideDataForType type: NSPasteboard.PasteboardType
        ) {}
    }

    /// Skipping a nil type is the right call and it rests on an assumption
    /// nobody can check from outside: that the flavour is derivable and the
    /// restore will bring it back. Measured, that assumption is sometimes
    /// wrong — a refused promise and a derivable flavour produce the same
    /// nil — and there is no property to tell them apart, so the skip stays.
    ///
    /// What changes is that it stops being invisible. If a user reports a
    /// clipboard that came back poorer than it went in, the trail names the
    /// types we dropped.
    @Test("a declared type with no bytes of its own is recorded as skipped")
    func askippedTypeIsRecorded() throws {
        withPrivatePasteboard { pasteboard in
            let item = NSPasteboardItem()
            item.setString("plain", forType: .string)
            item.setDataProvider(RefusingProvider(), forTypes: [.rtf])
            pasteboard.clearContents()
            pasteboard.writeObjects([item])

            let trace = FakeTrace()
            let transaction = PasteboardTransaction(pasteboard: pasteboard)
            transaction.trace = trace

            #expect(transaction.snapshot(), "the snapshot still succeeds — nothing is refused")

            let skipped = trace.events.compactMap { event -> String? in
                if case let .snapshotSkippedType(type) = event { return type }
                return nil
            }
            #expect(
                skipped.contains("public.rtf"),
                "the refused promise is named; recorded \(skipped)")
        }
    }

    /// Declining is right, and the transaction is still over. It did not say
    /// so: the change-count path returned without releasing, and the borrow
    /// outlived the work. `ReplacementService.pasteReplace` calls `handOff` on
    /// the very next line, that hand-off opens a second transaction on the
    /// same pasteboard, and the acquire fails — so the user is told "another
    /// rewrite is using the clipboard", which is false, and the rewrite is
    /// withheld from them instead of being copied for them.
    ///
    /// Third defect in this file's borrow lifetime. The pattern is that its
    /// early exits are not all covered, so a new one should be assumed
    /// uncovered until a test says otherwise.
    @Test("a restore that declines still gives the borrow back")
    func decliningToRestoreStillReleasesTheBorrow() throws {
        withPrivatePasteboard { pasteboard in
            // Its own registry: the shared one is process-wide and would
            // couple this to whatever else is running.
            let borrow = PasteboardBorrow()
            pasteboard.clearContents()
            pasteboard.setString("the user's original", forType: .string)

            let transaction = PasteboardTransaction(pasteboard: pasteboard, borrow: borrow)
            #expect(transaction.snapshot())
            transaction.writeTransient("scratch")

            pasteboard.clearContents()
            pasteboard.setString("what the user just copied", forType: .string)
            #expect(transaction.restoreIfUnchanged() == false)

            // The copy-only hand-off, which in production runs on the line
            // after the declined restore and with the first transaction still
            // in scope.
            let handOff = PasteboardTransaction(pasteboard: pasteboard, borrow: borrow)
            #expect(handOff.snapshot(), "nothing else holds the clipboard, so say so")
        }
    }

    /// After a synthetic ⌘C the *target app* was the writer, not us, so the
    /// transaction has to be told which change count to treat as its own.
    /// Without this the restore would always decline on the copy path.
    @Test("expect(changeCount:) lets a borrow the target app performed be handed back")
    func expectChangeCountCoversAWriteWeDidNotMake() throws {
        withPrivatePasteboard { pasteboard in
            pasteboard.clearContents()
            pasteboard.setString("the user's original", forType: .string)

            let transaction = PasteboardTransaction(pasteboard: pasteboard)
            #expect(transaction.snapshot())

            // The target app answers the synthetic ⌘C.
            pasteboard.clearContents()
            pasteboard.setString("the selection", forType: .string)
            transaction.expect(changeCount: pasteboard.changeCount)

            #expect(transaction.restoreIfUnchanged())
            #expect(pasteboard.string(forType: .string) == "the user's original")
        }
    }

    /// This was a Critical bug once, and it is the highest-value test here.
    ///
    /// When the clipboard holds one large item the budget drops every payload
    /// and the saved array ends up empty. The old code read that as *"the
    /// clipboard was empty to begin with"*, cleared the pasteboard and
    /// returned success. A 40 MB TIFF went in, an empty pasteboard came out,
    /// and the restore reported that it had worked — worse than doing nothing,
    /// because the user got no signal at all.
    ///
    /// The check therefore belongs at the *front*. By the time you are in
    /// `restoreIfUnchanged` the user's bytes are already gone from your copy
    /// and off the pasteboard, and there is nothing left to be careful with.
    @Test("content over the snapshot budget refuses up front and never writes to the pasteboard")
    func oversizedContentRefusesUpFrontAndTouchesNothing() throws {
        withPrivatePasteboard { pasteboard in
            let huge = Data(repeating: 0xAB, count: 20 * 1024 * 1024)
            let item = NSPasteboardItem()
            item.setData(huge, forType: .tiff)
            pasteboard.clearContents()
            pasteboard.writeObjects([item])
            let changeCountBefore = pasteboard.changeCount

            let transaction = PasteboardTransaction(pasteboard: pasteboard)

            #expect(transaction.snapshot() == false)
            #expect(transaction.fidelity == .lossy)
            #expect(transaction.canBorrow == false, "callers check this before anything writes")

            #expect(pasteboard.changeCount == changeCountBefore, "nothing was written")
            #expect(pasteboard.pasteboardItems?.first?.data(forType: .tiff) == huge)

            // The backstop, for a future caller who forgets the front check.
            #expect(transaction.restoreIfUnchanged() == false)
            #expect(pasteboard.changeCount == changeCountBefore)
            #expect(
                pasteboard.pasteboardItems?.first?.data(forType: .tiff) == huge,
                "all 20 MB are still there"
            )
        }
    }

    /// `notTaken`, `faithful` and `lossy` are three states because collapsing
    /// them into "did we save anything" is how the bug above happened. An
    /// empty saved array is not a fact about the clipboard, it is a fact about
    /// our copy of it — and these two cases produce the same empty array.
    @Test("fidelity distinguishes not-taken, faithful-but-empty and lossy")
    func fidelityKeepsTheThreeStatesApart() throws {
        withPrivatePasteboard { pasteboard in
            let untaken = PasteboardTransaction(pasteboard: pasteboard)
            #expect(untaken.fidelity == .notTaken)
            #expect(untaken.canBorrow == false)
            #expect(untaken.restoreIfUnchanged() == false, "nothing to put back")

            // A genuinely empty clipboard: saved is empty, and restoring to
            // empty is the correct answer.
            pasteboard.clearContents()
            let empty = PasteboardTransaction(pasteboard: pasteboard)
            #expect(empty.snapshot())
            #expect(empty.fidelity == .faithful)
            #expect(empty.canBorrow)
            empty.writeTransient("scratch")
            #expect(empty.restoreIfUnchanged())
            #expect(pasteboard.string(forType: .string) == nil)
        }
    }

    /// Proof the budget guard did not simply disable the feature.
    @Test("a payload comfortably under the budget still round-trips byte for byte")
    func underBudgetPayloadStillRoundTrips() throws {
        withPrivatePasteboard { pasteboard in
            let payload = Data((0..<(1024 * 1024)).map { UInt8($0 % 251) })
            let item = NSPasteboardItem()
            item.setData(payload, forType: .tiff)
            pasteboard.clearContents()
            pasteboard.writeObjects([item])

            let transaction = PasteboardTransaction(pasteboard: pasteboard)
            #expect(transaction.snapshot())
            #expect(transaction.fidelity == .faithful)
            transaction.writeTransient("scratch")
            #expect(transaction.restoreIfUnchanged())

            #expect(pasteboard.pasteboardItems?.first?.data(forType: .tiff) == payload)
        }
    }

    /// Measured, after an earlier version of this flag cried wolf on every
    /// rich clipboard: a declared type whose `data(forType:)` is nil has no
    /// bytes to lose. It is a flavour AppKit derives on demand, and the same
    /// machinery re-advertises it once the base types are back.
    @Test("a declared type carrying no bytes of its own does not make a snapshot lossy")
    func derivedTypesWithoutDataAreNotLossy() throws {
        withPrivatePasteboard { pasteboard in
            pasteboard.clearContents()
            pasteboard.setString("just a plain string", forType: .string)

            let transaction = PasteboardTransaction(pasteboard: pasteboard)
            #expect(transaction.snapshot())
            #expect(transaction.fidelity == .faithful)

            transaction.writeTransient("scratch")
            #expect(transaction.restoreIfUnchanged())
            #expect(pasteboard.string(forType: .string) == "just a plain string")
        }
    }

    private let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private let autoGeneratedType = NSPasteboard.PasteboardType(
        "org.nspasteboard.AutoGeneratedType")
    private let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// Without the markers, every single rewrite leaves a junk entry in the
    /// user's clipboard history. They ride on the same item as the text so
    /// they appear in `NSPasteboard.types`, which is where managers look.
    @Test("the scratch write is marked transient and auto-generated, and the restore is not")
    func scratchWriteCarriesClipboardManagerMarkers() throws {
        withPrivatePasteboard { pasteboard in
            pasteboard.clearContents()
            pasteboard.setString("the user's original", forType: .string)

            let transaction = PasteboardTransaction(pasteboard: pasteboard)
            #expect(transaction.snapshot())
            transaction.writeTransient("scratch")

            #expect(pasteboard.types?.contains(transientType) == true)
            #expect(pasteboard.types?.contains(autoGeneratedType) == true)
            #expect(
                pasteboard.types?.contains(concealedType) == false,
                "that one means 'this is a password' and would misuse the convention"
            )

            #expect(transaction.restoreIfUnchanged())
            #expect(
                pasteboard.types?.contains(transientType) == false,
                "the restored content is the user's own; a manager should record it"
            )
        }
    }

    /// `copiedOnly` promises the text is on the clipboard for the user to
    /// paste, so it has to survive and a clipboard manager should record it.
    /// This is the opposite of the scratch write and the two must not merge.
    @Test("a durable write carries no markers and is not restored away")
    func durableWriteIsUnmarkedAndSurvives() throws {
        withPrivatePasteboard { pasteboard in
            pasteboard.clearContents()
            pasteboard.setString("the user's original", forType: .string)

            let transaction = PasteboardTransaction(pasteboard: pasteboard)
            #expect(transaction.snapshot())
            transaction.writeDurable("the rewrite, for you to paste", keepOutOfHistory: false)

            #expect(pasteboard.string(forType: .string) == "the rewrite, for you to paste")
            #expect(pasteboard.types?.contains(transientType) == false)
            #expect(pasteboard.types?.contains(autoGeneratedType) == false)
        }
    }

    /// Whether the rewrite enters clipboard history is the user's call, and
    /// the default is that it does not — a rewrite is not something they
    /// copied.
    ///
    /// **The markers stop *recording*, not pasting.** A transient item is
    /// still on the pasteboard and ⌘V still works, which is what makes
    /// "off" safe as a default for the copy-only outcome: the promise
    /// `copiedOnly` carries is that the text is there to paste, and it is.
    ///
    /// Not `ConcealedType`, which the convention reserves for passwords and
    /// which makes some managers warn. Both markers rather than one, because
    /// managers differ in which they honour and both are true of a rewrite.
    @Test("a durable write is marked transient when the user keeps rewrites out of history")
    func durableWriteIsMarkedWhenHistoryIsOff() throws {
        withPrivatePasteboard { pasteboard in
            pasteboard.clearContents()
            pasteboard.setString("the user's original", forType: .string)

            let transaction = PasteboardTransaction(pasteboard: pasteboard)
            #expect(transaction.snapshot())
            transaction.writeDurable("the rewrite, for you to paste", keepOutOfHistory: true)

            #expect(
                pasteboard.string(forType: .string) == "the rewrite, for you to paste",
                "still there, and still pasteable by hand"
            )
            #expect(pasteboard.types?.contains(transientType) == true)
            #expect(pasteboard.types?.contains(autoGeneratedType) == true)
        }
    }
}
