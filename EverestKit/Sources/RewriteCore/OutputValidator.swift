import Foundation

/// Why a rewrite got rejected before it could replace a user's selection.
///
/// One case, and it used to be two. `lengthRatio` refused output more than 3×
/// the source — see `validate` for why a structural bound replaced it.
public enum ValidationFailure: Error, Equatable, Sendable {
    case empty
}

/// Cleans and sanity-checks raw model output before it can replace a user's
/// selection. See RewriteCore/AGENTS.md: this is the second layer of defense
/// behind PromptBuilder's safety frame, catching output that got hijacked or
/// otherwise stopped looking like a rewrite of the input.
///
/// **One cleaning rule survives, and it is the only one that was ever
/// provable.** The envelope carries a per-prompt random id, so "this is our
/// packaging" is a fact about the text rather than a guess about the model.
///
/// Two other rules used to live here and both deleted people's writing. A
/// conversational preamble was stripped by literal match, so selecting that
/// exact sentence removed it. Any outer pair of double quotes was stripped —
/// which the safety frame explicitly asks the model to *preserve* — so a
/// quoted passage came back unquoted, and a rewrite that merely opened and
/// closed on a quotation mark came back **unbalanced**.
///
/// Neither was salvageable by the source comparison that saved the envelope.
/// The preamble was one literal out of an unbounded set of things a model
/// might say, so it bought a single string's worth of tidiness. And no source
/// distinguishes `"…"` the model added from `"…"` the rewrite legitimately
/// begins and ends with. **A tidy-up that damages correct input is a worse
/// bug than the tic it was tidying**, and an unwanted preface or quote pair
/// is visible and undoable where a deleted sentence is neither. Do not add
/// either back.
public enum OutputValidator {

    /// The tags `PromptBuilder` wraps the selection in, echoed back around the
    /// answer.
    ///
    /// **Exactly sixteen hex digits**, which is the width `identifier()`
    /// zero-pads to — not `+`, which is the whole of a data-loss bug this
    /// once had. `[0-9a-fA-F]+` also matches `<selected_text_1>`, so a user
    /// rewriting their own `<selected_text_1>inner</selected_text_1>` had the
    /// sentence around it read as packaging and thrown away, and the fragment
    /// written to their document. `safetyFrame` makes that *more* likely, not
    /// less: it tells the model any other tag inside the block is part of the
    /// text to rewrite, so a compliant model echoes the user's tag faithfully.
    ///
    /// **This is unlikely, not impossible, and the comment that claimed
    /// otherwise is part of what let the bug live.** A false positive needs
    /// the user's own text to contain a 16-hex-digit tag *and* a closing tag
    /// carrying that same id, exactly once each. That is the same order of
    /// unlikelihood as an id collision, which is already accepted — but it is
    /// a probability, not a construction, and it should not be written up as
    /// one.
    ///
    /// The id is still matched as a pattern rather than threaded through from
    /// `PromptBuilder`: carrying the real value means four files across three
    /// modules for what is a cosmetic tic. This is a tidy-up, not a guard;
    /// containment is structural and lives in `PromptBuilder`.
    ///
    /// Computed, not `static let`: `Regex` is not `Sendable`, so a stored one
    /// is a concurrency error under Swift 6. Built once per rewrite.
    private static var openTag: Regex<(Substring, Substring)> {
        /<selected_text_([0-9a-fA-F]{16})>/
    }

    public static func clean(_ raw: String, source: String) -> String {
        unwrappedEnvelope(raw, source: source) ?? raw
    }

    /// What one echoed envelope contains, or `nil` if there is not exactly one.
    ///
    /// **Exactly one, and that bound is the whole of the safety here.** A
    /// model that restates its input before answering emits the pair twice,
    /// and the id proves both are ours while saying nothing about which
    /// delimits the rewrite. Spanning them — which a single greedy match over
    /// the whole output silently does — splices the user's own text, the
    /// commentary between, and the rewrite into one string and writes it to
    /// their document. Taking the first pair instead hands back their original
    /// as the rewrite. Both are silent and wrong; leaving the tags in place
    /// fails visibly, which is the trade this codebase makes everywhere else.
    ///
    /// The closing tag is searched for **by the opening tag's own id**, not by
    /// a second pattern. Two patterns would accept a close that carries a
    /// different id from the open — which is not an envelope at all, just two
    /// tag-shaped things in someone's text.
    ///
    /// **And the source decides whose tag it is.** Matching the shape is not
    /// enough: the cleaner accepts any well-formed id, so "the user's text
    /// happens to contain one" is not a 2⁶⁴ event — it is ordinary for anyone
    /// whose writing is *about* this app. Our id is drawn fresh for this one
    /// prompt, so a selection made beforehand cannot contain it unless the
    /// user typed that tag themselves. Asking the source is what turns the
    /// shape match back into the 2⁶⁴ claim the comment above used to make for
    /// free, and it needs nothing carried through from `PromptBuilder`.
    private static func unwrappedEnvelope(_ text: String, source: String) -> String? {
        let opens = text.matches(of: openTag)
        guard opens.count == 1, let opening = opens.first else { return nil }

        // Theirs, not ours.
        guard !source.contains(text[opening.range]) else { return nil }

        let closes = text.ranges(of: "</selected_text_\(opening.output.1)>")
        guard closes.count == 1, let close = closes.first,
            opening.range.upperBound <= close.lowerBound
        else { return nil }

        let open = opening.range

        // Exactly one newline each side, because that is exactly what
        // `PromptBuilder` puts there. Trimming all whitespace instead took
        // the indentation off the first line of an echoed code block and any
        // blank line a rewrite legitimately ended on — the same mistake as
        // trimming captured text, which root §6 forbids, and the reason
        // `validate` refuses blank output rather than trimming it.
        var inner = text[open.upperBound ..< close.lowerBound]
        if inner.hasPrefix("\n") { inner = inner.dropFirst() }
        if inner.hasSuffix("\n") { inner = inner.dropLast() }
        return String(inner)
    }

    /// `clean()`, then the one thing left worth refusing.
    ///
    /// **There used to be a 3× length ceiling here. It was removed because a
    /// structural bound replaced it, not because runaway output stopped
    /// mattering** — do not put a scanner back.
    ///
    /// What it stood for is now enforced where it is enforceable. Output is
    /// hard-bounded by `EngineLimits.outputBudget` at `contextCap -
    /// inputTokens`, and a generation that reaches that bound is refused by
    /// `MLXEngine` as `GenerationError.truncated`: a runaway generation *is* a
    /// budget-exhausted generation, caught exactly, at the decoder, instead of
    /// guessed at from a length afterwards.
    ///
    /// What the ceiling still caught was a hijack that stops cleanly at a few
    /// times the source — and that is the same band the built-in `Expand`
    /// style lives in. Expanding a short sentence honestly runs five to
    /// fifteen times, so the ceiling refused `Expand` every time on the only
    /// input anyone expands. Same lengths, same multiples, and no threshold
    /// between them, because the difference is not the length. Telling them
    /// apart needs intent, and the only thing carrying intent is
    /// `preset.instruction`, which is free text the user edits.
    ///
    /// The accepted cost: a hijacked rewrite now replaces the selection
    /// instead of being refused. That is visible on screen and ⌘Z undoes it in
    /// the target app — unlike the silent unrecoverable writes this project
    /// spends its budget avoiding.
    public static func validate(_ raw: String, source: String) -> Result<String, ValidationFailure> {
        let cleaned = clean(raw, source: source)
        // Blank, not merely zero-length. `"   \n\t "` is not a rewrite, and
        // writing it over the selection deletes the user's text silently —
        // the one failure this codebase will not accept. Checked here rather
        // than by trimming in `clean`, because refusing blank output costs
        // the user nothing while trimming everything that passes would
        // quietly edit rewrites that legitimately end in a newline.
        guard cleaned.contains(where: { !$0.isWhitespace }) else { return .failure(.empty) }
        return .success(cleaned)
    }
}
