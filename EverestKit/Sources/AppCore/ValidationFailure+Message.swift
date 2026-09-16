import RewriteCore

public extension ValidationFailure {
    /// Why the rewrite was thrown away, in words the user can act on.
    ///
    /// The `lengthRatio` sentence went with the 3× ceiling it described — see
    /// `OutputValidator.validate`: output is bounded at the decoder instead,
    /// and a generation that reaches that bound is reported by
    /// `GenerationError.truncated`, which has its own words.
    var message: String {
        switch self {
        case .empty:
            "The model returned nothing. Try again, or pick a different model in Settings."
        case .packagingOnly:
            // Deliberately does not blame the model or send anyone to swap
            // one. Every time this has been seen, the model answered exactly
            // what it was given and the fault was the capture handing it a
            // placeholder — so the sentence points at the selection.
            """
            Everest could not read your selection properly, so there was nothing to rewrite. \
            Try selecting the text again.
            """
        }
    }
}
