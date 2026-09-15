import RewriteCore

public extension ValidationFailure {
    /// Why the rewrite was thrown away, in words the user can act on.
    ///
    /// One case now. The `lengthRatio` sentence went with the 3× ceiling it
    /// described — see `OutputValidator.validate`: output is bounded at the
    /// decoder instead, and a generation that reaches that bound is reported
    /// by `GenerationError.truncated`, which has its own words.
    var message: String {
        switch self {
        case .empty:
            "The model returned nothing. Try again, or pick a different model in Settings."
        }
    }
}
