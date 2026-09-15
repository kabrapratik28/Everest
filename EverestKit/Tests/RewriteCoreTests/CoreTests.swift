import Testing
@testable import RewriteCore

// `PromptBuilder`'s tests live in `PromptBuilderTests.swift`.

// MARK: - OutputValidator.clean

@Test("OutputValidator.clean strips a conversational preamble")
func outputValidatorCleanStripsPreamble() {
    let raw = "Sure! Here's an improved version:\n\nThis is the rewritten text."
    let cleaned = OutputValidator.clean(raw)
    #expect(cleaned == "This is the rewritten text.")
}

@Test("OutputValidator.clean strips wrapping double quotes")
func outputValidatorCleanStripsWrappingQuotes() {
    let raw = "\"This is quoted.\""
    let cleaned = OutputValidator.clean(raw)
    #expect(cleaned == "This is quoted.")
}

@Test("OutputValidator.clean strips stray selected_text wrapper tags echoed back by the model")
func outputValidatorCleanStripsSelectedTextTags() {
    let raw = "<selected_text>This is the rewritten text.</selected_text>"
    let cleaned = OutputValidator.clean(raw)
    #expect(cleaned == "This is the rewritten text.")
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
