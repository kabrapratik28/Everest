/// Everest never writes an em dash. The frame asks the model not to, and a
/// 4B model mostly complies (0, 3 and 9 per 28 rewrites across three prompt
/// revisions, measured 2026-09-28), so this catches what gets through.
///
/// A dash between words becomes a comma, which reads right between clauses
/// and in dash pairs. A spaced en dash or double hyphen standing in for one
/// goes the same way; an unspaced en dash is a range (10–20) and stays, and a
/// double hyphen at a line's edge (an email signature, `--flag`) is left
/// alone. Code spans are split out on backticks and never touched.
enum EmDashes {
    static func replaced(in text: String) -> String {
        text.split(separator: "`", omittingEmptySubsequences: false)
            .enumerated()
            .map { $0.offset.isMultiple(of: 2) ? commas(String($0.element)) : String($0.element) }
            .joined(separator: "`")
    }

    private static func commas(_ prose: String) -> String {
        prose
            .replacing(/(\S)[ \t]*—[ \t]*(?=\S)/) { "\($0.output.1), " }
            .replacing(/(\S)[ \t]+(?:–|--)[ \t]+(?=\S)/) { "\($0.output.1), " }
            // What is left sits at a line's edge with nothing to join.
            .replacing(/[ \t]*—[ \t]*/, with: "")
    }
}
