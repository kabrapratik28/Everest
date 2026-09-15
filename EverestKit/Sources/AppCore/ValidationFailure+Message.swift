import RewriteCore

public extension ValidationFailure {
    /// Why the rewrite was thrown away, in words the user can act on.
    ///
    /// The ratio itself is deliberately not shown. "2.9 times longer" is a
    /// number about our threshold, not about their writing, and it invites the
    /// question "so what is the limit" — which is not a question the user
    /// should have to hold in their head to use a rewrite button.
    var message: String {
        switch self {
        case .empty:
            "The model returned nothing. Try again, or pick a different model in Settings."
        case .lengthRatio:
            "The model returned far more text than it was given, so your selection was left alone. Try a shorter passage, or a different style."
        }
    }
}
