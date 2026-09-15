import Foundation
import Synchronization
import TextBridge
import Testing

@testable import AppCore

private func makeOnboardingStore() -> UserDefaults {
    UserDefaults(suiteName: "com.kabrapratik.Everest.onboarding.\(UUID().uuidString)")!
}

/// The permission gate, and the reason it has to be read live.
///
/// Granting Accessibility happens in System Settings, in another process,
/// while the onboarding window is still open — that is the *normal* path, not
/// an edge case. A gate that reads `AXIsProcessTrusted()` once at launch stays
/// shut after the user has done exactly what it asked, and the only way out is
/// quitting an app they have not finished setting up yet.
///
/// Everything past this step is meaningless without the permission: the
/// capability table describes reads that cannot happen, the test rewrite has
/// nothing to read, so this is a gate rather than a suggestion.
@Test("onboarding stays on the permission step until it is granted, without a relaunch")
@MainActor
func onboardingGatesOnAccessibilityAndRereadsIt() {
    let trusted = Mutex(false)
    // A throwaway suite, not `.standard`. `advance()` persists the step now,
    // so a default store would write into the real user's defaults and hand
    // the next test a model that starts halfway through.
    let onboarding = OnboardingModel(
        store: makeOnboardingStore(),
        isAccessibilityTrusted: { trusted.withLock { $0 } }
    )

    #expect(onboarding.step == .accessibility)
    onboarding.advance()
    #expect(onboarding.step == .accessibility)

    // The user switches Everest on in System Settings. No relaunch.
    trusted.withLock { $0 = true }

    onboarding.advance()
    #expect(onboarding.step == .capabilities)
}

/// Past the gate, the steps are just an order.
@Test("the remaining steps run capabilities, then the model, then a real rewrite")
@MainActor
func stepsRunInOrderOnceThePermissionIsGranted() {
    let onboarding = OnboardingModel(store: makeOnboardingStore(), isAccessibilityTrusted: { true })

    var visited: [OnboardingModel.Step] = [onboarding.step]
    while onboarding.step != .tryIt {
        onboarding.advance()
        visited.append(onboarding.step)
    }

    #expect(visited == [.accessibility, .capabilities, .model, .tryIt])
    // The last step does not fall off the end.
    onboarding.advance()
    #expect(onboarding.step == .tryIt)
}

/// Whether setup happened and whether the permission is on are two different
/// questions, and the launch check was asking the wrong one.
///
/// It read `isAccessibilityTrusted()`. So a user who granted Accessibility
/// before ever opening the guide — from the Settings tab, or because macOS had
/// carried the grant over — was counted as set up and never saw the model
/// step, which is the step that puts a model on disk. There is no substitute
/// signal: the permission cannot tell you whether anyone read the capability
/// table or chose an engine. It has to be recorded separately.
@Test("setup is finished when the user finishes it, not when the permission is granted")
@MainActor
func completionIsRecordedSeparatelyFromThePermission() {
    let store = makeOnboardingStore()

    // Permission already on, guide never opened.
    let first = OnboardingModel(store: store, isAccessibilityTrusted: { true })
    #expect(first.isComplete == false)

    first.markComplete()
    #expect(first.isComplete)

    // A later launch reads the same store.
    #expect(OnboardingModel(store: store, isAccessibilityTrusted: { true }).isComplete)
}

/// Closing the window midway must not cost the user the steps they did.
///
/// Onboarding is an `NSWindow` with a close button, so abandoning it is one
/// click and entirely expected. Starting again from the permission step each
/// time makes the model step unreachable for anyone who ever closed the
/// window — the same dead end the completion flag exists to prevent, reached
/// from the other side.
@Test("a guide closed midway resumes at the step it stopped on")
@MainActor
func theStepSurvivesClosingTheWindow() {
    let store = makeOnboardingStore()

    let first = OnboardingModel(store: store, isAccessibilityTrusted: { true })
    first.advance()
    first.advance()
    #expect(first.step == .model)

    let resumed = OnboardingModel(store: store, isAccessibilityTrusted: { true })
    #expect(resumed.step == .model)
    #expect(resumed.isComplete == false)
}

/// The capability table, and why it is a requirement rather than marketing.
///
/// "Works anywhere" is true of *reading* a selection and false of writing one.
/// A user who first meets that limit in Ghostty, mid-sentence, with no warning,
/// concludes the app is broken — where the same behaviour announced up front is
/// a tool handing them the clipboard. The password row is the other half: the
/// refusal is the app working, and a user who is not told will assume it failed
/// and try somewhere less safe.
@Test("the capability table admits what cannot be replaced, and that passwords are never read")
func theCapabilityTableStatesTheLimits() {
    let rows: [OnboardingModel.Capability] = OnboardingModel.capabilities

    let terminal = rows.first { $0.context.contains("Terminal") }
    #expect(terminal?.replace == .copyOnly)

    let password = rows.first { $0.context.contains("Password") }
    #expect(password?.capture == .never)
    #expect(password?.replace == .refused)

    // Something has to be replaceable in place, or the table is describing a
    // different app.
    #expect(rows.contains { $0.replace == .inPlace })
}

/// Onboarding must not let the excluded-app list look like the whole defence.
///
/// Matching in `SelectionCoordinator` is case-insensitive and **exact**,
/// deliberately not prefix, so every entry is one native app. Banking on a Mac
/// is overwhelmingly a browser tab, which no entry on any list will ever
/// cover. The thing that actually protects a web or Electron password field is
/// the secure-subrole check — and those fields do not set the process-wide
/// secure-input flag either, so the subrole check is the *only* thing
/// protecting them.
///
/// A user who believes the list is the protection will add their bank's name
/// to it, get nothing, and never know. Saying so is a requirement, which is
/// why the sentence lives here with a test rather than loose in a view.
@Test("onboarding says the excluded-app list is not what protects a password field")
func theExclusionCaveatNamesTheRealProtection() {
    let caveat = OnboardingModel.exclusionCaveat

    #expect(caveat.localizedCaseInsensitiveContains("secure"))
    // It has to name the case the list cannot cover, or it is not a caveat.
    #expect(caveat.localizedCaseInsensitiveContains("browser"))
}

/// Onboarding will not move off the model step while a download is running.
///
/// "Use and download" starts preparation and Continue stayed live, so the
/// user could reach the practice step and press the hotkey while the first
/// transfer was still going. `LoadOnce` deduplicates the *load*, not the
/// *download*, so two `prepare` calls that both see no ready marker start
/// two transfers of the same gigabytes.
///
/// Gated on *preparing*, deliberately, not on *ready*. Ready would strand
/// anyone whose download failed, or who meant to skip and pick a model
/// later; in-flight is the narrow condition that actually races.
@Test("onboarding will not leave the model step while a download is in flight")
@MainActor
func onboardingWaitsForAnInFlightDownload() {
    let downloading = Mutex(true)
    let onboarding = OnboardingModel(
        store: makeOnboardingStore(),
        isAccessibilityTrusted: { true },
        isPreparing: { downloading.withLock { $0 } }
    )

    onboarding.advance()
    onboarding.advance()
    #expect(onboarding.step == .model)

    onboarding.advance()
    #expect(onboarding.step == .model, "left the model step mid-download")

    downloading.withLock { $0 = false }
    onboarding.advance()
    #expect(onboarding.step == .tryIt)
}

/// The password promise must not be absolute, because the implementation is
/// not.
///
/// It said "Password and secure fields are never read. Everest refuses before
/// it looks." Two real guards stand behind that — the `AXSecureTextField`
/// subrole refusal, and `IsSecureEventInputEnabled` checked at the top of the
/// chain and again immediately before any clipboard read. Neither can reach
/// an app that exposes no accessibility tree *and* leaves the process-wide
/// flag clear: there is no element to classify and no flag to see.
///
/// Chrome 153 sets the flag. Nothing obliges an Electron host, a custom
/// control, or a later Chrome to. **A measurement of one host at one version
/// was standing in for a security invariant covering every app forever** —
/// the same shape that cost a P0 investigation earlier today, in this area.
///
/// The absolutes are forbidden rather than merely avoided, because the
/// pressure on copy like this is always back toward the reassuring version.
@Test("the password promise names what is enforced and what is not, and claims nothing absolute")
func thePasswordPromiseIsNotAbsolute() {
    let promise = OnboardingModel.passwordPromise

    // What is genuinely enforced has to survive, or honesty costs the user
    // the reassurance the guards have actually earned.
    #expect(promise.localizedCaseInsensitiveContains("password"))
    #expect(promise.localizedCaseInsensitiveContains("refuses"))

    // And the residual has to be named, specifically enough to picture.
    #expect(promise.localizedCaseInsensitiveContains("accessibility"))

    // No absolute claim, in any of the three forms it keeps coming back as.
    for absolute in ["never", "always", "cannot"] {
        #expect(
            promise.localizedCaseInsensitiveContains(absolute) == false,
            "\"\(absolute)\" is a guarantee the capture chain does not make"
        )
    }

    // A residual the user can do nothing about is just anxiety, so it ends
    // on the one control that does cover a whole app.
    #expect(promise.localizedCaseInsensitiveContains("Settings"))

    // The same rule, the other surface. The refusal message said "Everest
    // never reads passwords" — the identical unprovable guarantee, reached
    // by a different screen. One rule, so one test: a spot-fix here would
    // have left the drift alive in whichever string was not being edited.
    let refusal = CaptureFailure.message(for: CaptureError.secureField)
    #expect(refusal.localizedCaseInsensitiveContains("never") == false)
    // It still has to say the refusal *is* the app working, or the user
    // reads a failure and tries somewhere less careful.
    #expect(refusal.localizedCaseInsensitiveContains("nothing was read"))
}
