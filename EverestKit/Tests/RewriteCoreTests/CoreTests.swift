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

@Test("OutputValidator.validate rejects output more than 3.0x the source length")
func outputValidatorValidateRejectsExcessiveLengthRatio() {
    let source = "1234567890" // 10 characters
    let raw = String(repeating: "x", count: 40) // 40 characters -> 4.0x ratio
    let result = OutputValidator.validate(raw, source: source)
    guard case .failure(let failure) = result else {
        Issue.record("expected .failure for output more than 3x source length, got \(result)")
        return
    }
    #expect(failure == .lengthRatio(4.0))
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
