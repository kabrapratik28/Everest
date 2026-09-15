import Testing
@testable import RewriteCore

// `PromptBuilder`'s tests live in `PromptBuilderTests.swift`.

// MARK: - OutputValidator.clean

@Test("OutputValidator.clean strips a conversational preamble")
func outputValidatorCleanStripsPreamble() {
    let raw = "Sure! Here's an improved version:\n\nThis is the rewritten text."
    let cleaned = OutputValidator.clean(raw, source: "this is the rewritten text")
    #expect(cleaned == "This is the rewritten text.")
}

/// The model wrapped its answer in quotes the user did not ask for. That is
/// packaging, and the safety frame already tells it not to.
@Test("OutputValidator.clean strips quotes the model added around its answer")
func outputValidatorCleanStripsWrappingQuotes() {
    let raw = "\"This is quoted.\""
    let cleaned = OutputValidator.clean(raw, source: "this is quoted")
    #expect(cleaned == "This is quoted.")
}

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
@Test("OutputValidator.clean leaves selected_text tags that are the user's own text")
func outputValidatorCleanKeepsTheUsersOwnTags() {
    let source = "the parser must handle <selected_text> and </selected_text> correctly"
    let raw = "The parser must handle <selected_text> and </selected_text> correctly."
    let cleaned = OutputValidator.clean(raw, source: source)
    #expect(cleaned == raw)
}

/// **Quotes the user wrote are not packaging either.**
///
/// Stripping any outer pair also contradicts the safety frame, which tells
/// the model to preserve quotation marks. Worse than losing them: a source
/// with two quoted phrases comes back *unbalanced* —
/// `"A" and "B"` became `A" and "B`.
@Test("OutputValidator.clean keeps quotes when the source was quoted too")
func outputValidatorCleanKeepsTheUsersOwnQuotes() {
    let source = "\"quote one\" and \"quote two\""
    let raw = "\"Quote A\" and \"Quote B\""
    let cleaned = OutputValidator.clean(raw, source: source)
    #expect(cleaned == raw)
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

@Test("Preset.builtInStyles has exactly 5 presets with unique names")
func presetBuiltInStylesHasExactlyFiveUniqueNames() {
    let styles = Preset.builtInStyles
    #expect(styles.count == 5)

    let uniqueNames = Set(styles.map(\.name))
    #expect(uniqueNames.count == 5)
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
