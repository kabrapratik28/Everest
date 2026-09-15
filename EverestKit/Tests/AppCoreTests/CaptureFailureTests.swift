import Testing
import TextBridge
@testable import AppCore

/// Regression test for a bug found by using the app.
///
/// The user had Accessibility switched on in System Settings and still got
/// "Rewrite failed". The grant had gone stale: TCC binds it to the code
/// signature, the app had been rebuilt, and an ad-hoc signature is a hash of
/// the binary — so the switch pointed at an identity that no longer existed
/// and `AXIsProcessTrusted()` returned false.
///
/// The signing fix stops it recurring. This test covers the other half: the
/// message told the user to do the thing they had already done, so following
/// it exactly could not work and gave them nowhere to go.
@Suite("Accessibility refusal message")
struct CaptureFailureTests {

    @Test("tells a user whose switch is already on what to do instead")
    func coversAnAlreadyEnabledSwitch() {
        let message = CaptureFailure.message(for: CaptureError.accessibilityNotGranted)

        // Someone reading this has the switch on and the app still refusing.
        // "Switch Everest on" alone is a dead end for exactly that person.
        #expect(
            message.localizedCaseInsensitiveContains("already on"),
            "must address the case where the permission looks granted"
        )
        // Removing and re-adding is the remedy, because it clears the stale
        // TCC record and lets the current signature be granted.
        #expect(
            message.localizedCaseInsensitiveContains("remove"),
            "must name the fix, not just the symptom"
        )
    }

    @Test("still tells a user who has never granted it how to grant it")
    func stillCoversTheFirstRun() {
        let message = CaptureFailure.message(for: CaptureError.accessibilityNotGranted)

        // The stale-grant advice must not crowd out the common case.
        #expect(message.localizedCaseInsensitiveContains("Accessibility"))
        #expect(message.localizedCaseInsensitiveContains("System Settings"))
    }
}
