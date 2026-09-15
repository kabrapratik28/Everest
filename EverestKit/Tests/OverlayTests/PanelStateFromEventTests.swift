import Testing
import RewriteCore
@testable import Overlay

@Suite("PanelState from RewriteEvent")
struct PanelStateFromEventTests {
    /// The engine-event to panel-state mapping is written once, here, so the
    /// coordinator cannot grow a second copy of it that drifts.
    @Test("each engine event maps to the panel state that describes it")
    func eventsMapToStates() {
        #expect(PanelState(.preparing(progress: nil)) == .preparing(progress: nil))
        #expect(PanelState(.preparing(progress: 0.25)) == .preparing(progress: 0.25))
        #expect(PanelState(.outputSnapshot("half a par")) == .generating(text: "half a par"))
    }

    /// `finished` is not the end of the user's transaction — the coordinator
    /// still has to validate the output and write it back, and that is the
    /// slowest visible step on a large selection. Showing the finished text as
    /// though nothing more were happening would make a successful replacement
    /// look like a hang.
    @Test("a finished stream says the app is applying the result, not that it is done")
    func finishedMeansApplying() {
        #expect(PanelState(.finished("the whole rewrite")) == .applying)
    }
}
