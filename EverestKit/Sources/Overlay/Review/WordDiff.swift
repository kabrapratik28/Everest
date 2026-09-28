/// One run of the review panel's changes view.
public enum DiffSegment: Equatable, Sendable {
    case same(String)
    case removed(String)
    case added(String)
}

/// Word-level differences between the text the user selected and the rewrite.
///
/// Tokens are words *with* their trailing whitespace, compared without it: a
/// changed line break is not a changed word, and joining the `same` and
/// `added` runs gives back the rewrite exactly. Nothing here trims.
public enum WordDiff {
    public static func segments(from original: String, to rewrite: String) -> [DiffSegment] {
        let old = tokens(original)
        let new = tokens(rewrite)
        var removed = Set<Int>()
        var added = Set<Int>()
        for change in new.difference(from: old, by: { word($0) == word($1) }) {
            switch change {
            case let .remove(offset, _, _): removed.insert(offset)
            case let .insert(offset, _, _): added.insert(offset)
            }
        }

        // Removals first at each change, the order track changes is read in.
        var runs: [DiffSegment] = []
        var i = 0
        var j = 0
        while i < old.count || j < new.count {
            if i < old.count, removed.contains(i) {
                runs.append(.removed(old[i])); i += 1
            } else if j < new.count, added.contains(j) {
                runs.append(.added(new[j])); j += 1
            } else {
                runs.append(.same(new[j])); i += 1; j += 1
            }
        }
        return merged(runs)
    }

    /// A replaced word is one change: a run of removals and additions counts
    /// once, however many words it spans.
    public static func changeCount(_ segments: [DiffSegment]) -> Int {
        var count = 0
        var inChange = false
        for segment in segments {
            if case .same = segment {
                inChange = false
            } else if !inChange {
                count += 1
                inChange = true
            }
        }
        return count
    }

    /// Each word with the whitespace after it; leading whitespace is a token
    /// of its own, so the tokens always join back into the text.
    private static func tokens(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inTrailingSpace = false
        for character in text {
            if character.isWhitespace {
                current.append(character)
                inTrailingSpace = true
            } else {
                if inTrailingSpace { result.append(current); current = "" }
                current.append(character)
                inTrailingSpace = false
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func word(_ token: String) -> Substring {
        token.prefix { !$0.isWhitespace }
    }

    private static func merged(_ runs: [DiffSegment]) -> [DiffSegment] {
        var result: [DiffSegment] = []
        for run in runs {
            switch (result.last, run) {
            case let (.same(a)?, .same(b)): result[result.count - 1] = .same(a + b)
            case let (.removed(a)?, .removed(b)): result[result.count - 1] = .removed(a + b)
            case let (.added(a)?, .added(b)): result[result.count - 1] = .added(a + b)
            default: result.append(run)
            }
        }
        return result
    }
}
