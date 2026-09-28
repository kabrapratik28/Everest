import Testing
@testable import Overlay

@Suite("WordDiff")
struct WordDiffTests {
    @Test("unchanged words stay plain, and a changed word is shown removed then added")
    func marksOnlyWhatChanged() {
        #expect(WordDiff.segments(from: "the drop is mostly one cohort", to: "The drop is mostly in one cohort") == [
            .removed("the "), .added("The "), .same("drop is mostly "), .added("in "), .same("one cohort"),
        ])
    }

    /// The changes view is drawn from these runs, so the kept and added runs
    /// must give back the rewrite exactly: nothing trimmed, nothing re-spaced.
    @Test("the kept and added runs give back the rewrite exactly, whitespace included")
    func rebuildsTheRewrite() {
        let rewrite = "Hey,  I looked\nat it. "
        let rebuilt = WordDiff.segments(from: "hey, looked at it", to: rewrite).map { segment -> String in
            switch segment {
            case let .same(text), let .added(text): text
            case .removed: ""
            }
        }.joined()
        #expect(rebuilt == rewrite)
    }

    @Test("a replaced word is one change, and an unchanged text has none")
    func countsChanges() {
        #expect(WordDiff.changeCount(WordDiff.segments(from: "its fine then", to: "it's fine than")) == 2)
        #expect(WordDiff.changeCount(WordDiff.segments(from: "same words", to: "same words")) == 0)
    }
}
