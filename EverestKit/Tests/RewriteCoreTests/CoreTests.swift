import Testing
@testable import RewriteCore

// `PromptBuilder`'s tests live in `PromptBuilderTests.swift`.

// MARK: - OutputValidator.clean

/// The envelope carries a per-prompt id (`PromptBuilder.build`), so an echoed
/// wrapper always has one. Stripping the bare literal, as this used to, now
/// matches nothing the model was ever shown.
@Test("OutputValidator.clean unwraps an echoed envelope carrying its per-prompt id")
func outputValidatorCleanUnwrapsNoncedEnvelope() {
    let raw = "<selected_text_3f2a19bb7c0d4e51>\nThis is the rewritten text.\n</selected_text_3f2a19bb7c0d4e51>"
    let cleaned = OutputValidator.clean(raw, source: "this is the rewritten text")
    #expect(cleaned == "This is the rewritten text.")
}

/// Trailing chatter is outside the envelope, so the envelope still bounds the
/// answer.
///
/// The id is what makes this exact rather than a guess: the user's text
/// cannot contain an unpredictable 64-bit id, so anything outside a pair
/// carrying one is the model talking, by construction — not a judgement about
/// which bits look like commentary.
@Test("OutputValidator.clean unwraps an envelope the model followed with commentary")
func outputValidatorCleanUnwrapsAnEnvelopeFollowedByChatter() {
    let raw = """
        <selected_text_3f2a19bb7c0d4e51>The report is ready.</selected_text_3f2a19bb7c0d4e51>

        Let me know if you'd like any other changes!
        """
    let cleaned = OutputValidator.clean(raw, source: "the report is ready")
    #expect(cleaned == "The report is ready.")
}

/// **Two envelopes means we do not know which one is the answer, so we do not
/// guess.**
///
/// A model that restates its input before answering emits the pair twice. The
/// id proves both are ours; it says nothing about which delimits the rewrite.
/// First-open-to-last-close yields a mangled splice, and first-open-to-first-
/// close hands back *the user's own text* as the rewrite — both silent and
/// both wrong. Leaving the tags in place fails visibly instead, which is the
/// trade this codebase makes everywhere else.
@Test("OutputValidator.clean leaves output alone when the envelope appears twice")
func outputValidatorCleanRefusesToGuessBetweenTwoEnvelopes() {
    let raw = """
        <selected_text_3f2a19bb7c0d4e51>the report is ready</selected_text_3f2a19bb7c0d4e51>

        Here is the rewrite:
        <selected_text_3f2a19bb7c0d4e51>The report is ready.</selected_text_3f2a19bb7c0d4e51>
        """
    let cleaned = OutputValidator.clean(raw, source: "the report is ready")
    #expect(cleaned == raw)
}

/// **The user's own text is not packaging.**
///
/// `clean` used to delete every `<selected_text>` occurrence anywhere in the
/// output, so anyone rewriting documentation or code that mentions the tag
/// had it silently removed from their own sentence. Two things make this
/// safe now: only a wrapper around the *whole* output is unwrapped, and only
/// one carrying a per-prompt id — and the model is never shown a bare tag, so
/// a bare tag in the output can only have come from the user.
/// Two payloads, because only one of them can fail.
///
/// The bare-tag case has never been able to fail: the pattern requires an
/// `_` and an id, so `<selected_text>` was never going to match it whatever
/// the pattern said. A test that cannot fail guarded nothing — which is the
/// third time in this one function that a passing test has sat in front of a
/// live defect, after the injection escape and the dead literal strip.
///
/// The **id-shaped** case is the one with teeth, and it was failing: an id of
/// `1` satisfies "one or more hex digits", so a user's own
/// `<selected_text_1>…</selected_text_1>` was read as our envelope and
/// everything outside it — the whole rest of their sentence — was discarded
/// and the fragment written to their document.
@Test("OutputValidator.clean leaves selected_text tags that are the user's own text")
func outputValidatorCleanKeepsTheUsersOwnTags() {
    let bare = "The parser must handle <selected_text> and </selected_text> correctly."
    #expect(OutputValidator.clean(bare, source: bare.lowercased()) == bare)

    let idShaped = "Keep this. <selected_text_1>inner</selected_text_1> And keep this too."
    #expect(OutputValidator.clean(idShaped, source: idShaped.lowercased()) == idShaped)
}

/// **`clean` no longer strips conversational preambles.**
///
/// It removed one hardcoded literal, unconditionally, so selecting that exact
/// sentence and having the model faithfully preserve it deleted it from the
/// document. The source-aware version was available — strip only when the
/// source did not begin with it — and was not worth keeping, because the
/// literal is one sample of an unbounded set of things a model might say. It
/// never fired on "Here's the improved version:" or any other phrasing, so
/// what it bought was a single string's worth of tidiness against a
/// deterministic deletion. `safetyFrame` already asks for no preface, and a
/// preface that arrives anyway is visible and undoable; a deleted sentence is
/// neither.
@Test("OutputValidator.clean leaves a conversational preamble the user selected")
func outputValidatorCleanLeavesAPreambleAlone() {
    let text = "Sure! Here's an improved version:\n\nThe phrase this app used to delete."
    #expect(OutputValidator.clean(text, source: text) == text)
}

/// **`clean` no longer strips outer quotation marks.**
///
/// Two payloads, and the second is why the rule could not be repaired rather
/// than merely made source-aware.
///
/// The first is the reported bug: comparing against a source of `"Hello"\n`
/// reads as unquoted, because the trailing newline defeats `hasSuffix`, so
/// the model's faithful quotes are removed. Ignoring whitespace in that
/// comparison would fix it — a second heuristic propping up the first.
///
/// The second cannot be fixed that way at all. A rewrite that legitimately
/// *opens and closes* with a quotation mark is indistinguishable from one the
/// model wrapped, and the source is no help because the source is not quoted
/// either. The old rule turned it **unbalanced**, which is worse than either
/// keeping or dropping the pair.
@Test("OutputValidator.clean leaves quotation marks alone")
func outputValidatorCleanLeavesQuotationMarksAlone() {
    let quotedWithNewline = "\"Hello there\""
    #expect(OutputValidator.clean(quotedWithNewline, source: "\"Hello\"\n") == quotedWithNewline)

    let dialogue = "\"Hello,\" he said, and she replied, \"Goodbye.\""
    #expect(
        OutputValidator.clean(dialogue, source: "he said hello and she said goodbye") == dialogue
    )
}

/// Unwrapping removes the envelope, not the first line's indentation.
///
/// `PromptBuilder` puts the text on its own line, so there is **exactly one**
/// newline inside each tag and those two belong to us. Trimming all
/// whitespace instead took the leading spaces off an echoed code block and
/// any blank line the rewrite legitimately ended on. Root §6 refuses to trim
/// captured text for the same reason, and `validate` already refuses blank
/// output rather than trimming it — this is that rule, one function along.
@Test("OutputValidator.clean strips the envelope's own newlines and no other whitespace")
func outputValidatorCleanKeepsIndentationInsideAnEnvelope() {
    let raw = "<selected_text_3f2a19bb7c0d4e51>\n    let x = 1\n</selected_text_3f2a19bb7c0d4e51>"
    let cleaned = OutputValidator.clean(raw, source: "    let x = 1")
    #expect(cleaned == "    let x = 1")
}

/// **A well-formed envelope the *user* wrote is still the user's text.**
///
/// The id-width fix stopped `<selected_text_1>` being read as packaging, but
/// left the real case: text containing a genuine 16-hex-shaped pair. That is
/// not a 1-in-2⁶⁴ collision with this prompt's id, because the cleaner
/// accepted *any* well-formed one — it is "does the selection contain a tag
/// of that shape", and the people whose text does are the ones working on
/// this app. The string below is copied from this very file.
///
/// Decided by asking the **source**, which `clean` already has, and which
/// every other rule in it already consults. Our id is generated fresh per
/// prompt, so it cannot appear in a selection the user made beforehand —
/// unless they wrote the tag themselves, which is precisely the case to
/// leave alone. That restores the 2⁶⁴ the earlier comment claimed, without
/// carrying the real id through two engines and three modules.
@Test("OutputValidator.clean keeps an envelope-shaped pair the user wrote themselves")
func outputValidatorCleanKeepsAUserAuthoredEnvelope() {
    let text =
        "Keep this. <selected_text_3f2a19bb7c0d4e51>inner</selected_text_3f2a19bb7c0d4e51> And this."
    #expect(OutputValidator.clean(text, source: text) == text)
}

// MARK: - OutputValidator.validate

@Test("OutputValidator.validate rejects empty output")
func outputValidatorValidateRejectsEmpty() {
    let result = OutputValidator.validate("", source: "Some source text.")
    guard case .failure(let failure) = result else {
        Issue.record("expected .failure for empty output, got \(result)")
        return
    }
    #expect(failure == .empty)
}

/// **Whitespace is not a rewrite, and writing it deletes the selection.**
///
/// `.empty` used to mean literally zero characters, so a model that returned
/// `"   \n\t "` passed validation and `ReplacementService` wrote it over the
/// user's text — a silent, unrecoverable deletion, which is the exact class
/// this project spends its budget avoiding. It was reachable before the 3×
/// ceiling came out (blank output is short, so the ratio never fired on it)
/// and removing the ceiling did not change that either way.
///
/// The blank check lives in `validate`, not `clean`: refusing blank output
/// costs the user nothing, whereas trimming everything that passes would
/// silently edit rewrites that legitimately end in a newline.
@Test("OutputValidator.validate rejects output that is only whitespace")
func outputValidatorValidateRejectsWhitespaceOnlyOutput() {
    let result = OutputValidator.validate("   \n\t ", source: "short")

    guard case .failure(let failure) = result else {
        Issue.record("expected .failure for whitespace-only output, got \(result)")
        return
    }
    #expect(failure == .empty)
}

/// **`Expand` is a built-in style, and the validator used to refuse it.**
///
/// `Presets.swift` ships "Expand this with more supporting detail and clarity
/// while preserving the original meaning." On a short selection — the only
/// input anyone expands — an honest expansion is five to fifteen times the
/// source, so a 3× ceiling refused the thing the user had just asked for,
/// every time.
///
/// It could not be tuned out. The band where a ratio still caught something
/// (a hijack that stops cleanly at a few times the source) is the *same* band
/// `Expand` lives in: same lengths, same multiples. Nothing separates them,
/// because the difference between them is not the length.
///
/// What made the ceiling removable rather than merely inconvenient is that
/// the thing it stood for now exists structurally: output is bounded by
/// `EngineLimits.outputBudget` at `contextCap - inputTokens`, and a
/// generation that reaches that bound is refused by `MLXEngine` as
/// `GenerationError.truncated`. **A runaway generation is a budget-exhausted
/// generation**, caught exactly, at the decoder.
@Test("OutputValidator.validate accepts an expansion far longer than its source")
func outputValidatorValidateAcceptsAnExpansion() {
    let source = "we need to fix the login bug."
    let raw = """
        We need to fix the login bug. It is currently blocking sign-in for a \
        subset of users, and until it is resolved those people cannot reach \
        their accounts at all, so it should be treated as urgent.
        """
    #expect(Double(raw.count) / Double(source.count) > 3.0, "the case is only interesting above 3×")

    let result = OutputValidator.validate(raw, source: source)

    guard case .success(let value) = result else {
        Issue.record("expected .success for an honest expansion, got \(result)")
        return
    }
    #expect(value == raw)
}

@Test("OutputValidator.validate accepts a reasonable rewrite")
func outputValidatorValidateAcceptsReasonableRewrite() {
    let source = "This is the original sentence that needs improving."
    let raw = "This is the improved sentence."
    let result = OutputValidator.validate(raw, source: source)
    guard case .success(let value) = result else {
        Issue.record("expected .success for a reasonable rewrite, got \(result)")
        return
    }
    #expect(value == raw)
}

// MARK: - Preset

/// **Names and UUIDs are pinned; instruction wording deliberately is not.**
///
/// A UUID is persistence: `AppSettings` Codable-round-trips styles through
/// `UserDefaults`, so changing one silently orphans a user's edit of that
/// style and the picker gets a duplicate. Order is the picker's reading
/// order. Both are facts a future edit can break without noticing.
///
/// The instruction strings are not pinned, on purpose. They are prompt
/// wording, expected to be tuned against the model, and a test that copies
/// them asserts the data equals itself — it fails on every honest
/// improvement and catches no bug. The one property of the wording that does
/// matter has its own test below.
@Test("Preset.builtInStyles is the six documented styles, in order, with stable ids")
func presetBuiltInStylesIsTheSixDocumentedStyles() {
    let expected: [(String, String)] = [
        ("Proofread", "11111111-1111-1111-1111-111111111111"),
        ("Professional", "22222222-2222-2222-2222-222222222222"),
        ("Friendly", "33333333-3333-3333-3333-333333333333"),
        ("Concise", "44444444-4444-4444-4444-444444444444"),
        ("Expand", "55555555-5555-5555-5555-555555555555"),
        ("Simplify", "66666666-6666-6666-6666-666666666666"),
    ]

    let styles = Preset.builtInStyles
    #expect(styles.map(\.name) == expected.map(\.0))
    #expect(styles.map { $0.id.uuidString.lowercased() } == expected.map(\.1))
    #expect(styles.allSatisfy { !$0.instruction.isEmpty && !$0.subtitle.isEmpty })
}

/// **Quick Improve must not be one of the picker's styles wearing a second
/// UUID.** It used to be: `quickImprove` and the picker's "Improve" shipped
/// the same instruction, so the hotkey and the picker's first row did the
/// same thing and one of the six choices was spent on it. Proofread took that
/// slot — corrections only, no stylistic rewriting — which is a different
/// behaviour from Quick Improve's broad clean-up.
///
/// Compared by instruction rather than by name because the instruction is
/// what reaches the model; two presets with different names and identical
/// instructions are still one behaviour offered twice.
@Test("Preset.quickImprove is not a duplicate of any picker style")
func presetQuickImproveIsNotADuplicateOfAPickerStyle() {
    let quick = Preset.quickImprove.instruction
    #expect(!quick.isEmpty)
    #expect(!Preset.builtInStyles.contains { $0.instruction == quick })
}

// MARK: - ModelCatalog

@Test("ModelCatalog.all has exactly one isDefault entry, and it is .qwen4B")
func modelCatalogHasExactlyOneDefaultAndItIsQwen4B() {
    let defaults = ModelCatalog.all.filter(\.isDefault)
    #expect(defaults.count == 1)
    #expect(defaults.first?.id == .qwen4B)
}

@Test("ModelCatalog.all pins a non-empty revision for every entry")
func modelCatalogHasNonEmptyRevisionForEveryEntry() {
    #expect(ModelCatalog.all.allSatisfy { !$0.revision.isEmpty })
}
