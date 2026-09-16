import Foundation
import os
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
    let trusted = OSAllocatedUnfairLock(initialState: false)
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
    #expect(onboarding.step == .model)
}

/// Past the gate, the steps are just an order.
@Test("past the gate it is the model, then a real rewrite")
@MainActor
func stepsRunInOrderOnceThePermissionIsGranted() {
    let onboarding = OnboardingModel(store: makeOnboardingStore(), isAccessibilityTrusted: { true })

    var visited: [OnboardingModel.Step] = [onboarding.step]
    while onboarding.step != .tryIt {
        onboarding.advance()
        visited.append(onboarding.step)
    }

    #expect(visited == [.accessibility, .model, .tryIt])
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
    #expect(first.step == .model)

    let resumed = OnboardingModel(store: store, isAccessibilityTrusted: { true })
    #expect(resumed.step == .model)
    #expect(resumed.isComplete == false)
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
    let downloading = OSAllocatedUnfairLock(initialState: true)
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

/// **A permission that goes away has to bring the guide back.**
///
/// macOS binds Accessibility to the code signature, so anything that changes
/// it revokes the grant: a rebuild with a different certificate, and, the
/// one that will hit every existing user at once, moving from an Apple
/// Development certificate to a notarised Developer ID one. The switch in
/// System Settings stays on while `AXIsProcessTrusted()` returns false.
///
/// Before this, the launch gate read `isComplete` alone. Someone who had
/// finished setup and then lost the grant got no guide, no explanation, and
/// a capture refusal on the next hotkey press, with nothing pointing at the
/// pane that fixes it.
///
/// **This is not the rule it looks like.** `AGENTS.md` says completion is
/// stored and never *inferred from* the grant, because a grant cannot tell
/// you whether anyone chose an engine, and reading it that way once let
/// people skip the model step entirely. That still holds: a grant never
/// marks anything complete. This is the opposite direction, where a grant
/// that has gone missing reopens a guide already marked finished.
@Test("a guide already finished reopens when the permission is taken away")
@MainActor
func aRevokedPermissionReopensTheGuide() {
    // Every combination, because the interesting one is only interesting
    // next to the three that must not change.
    #expect(OnboardingModel.opensAtLaunch(isComplete: false, isGranted: false))
    #expect(OnboardingModel.opensAtLaunch(isComplete: false, isGranted: true),
            "granting early must not skip the guide: that is the model-step bug")
    #expect(OnboardingModel.opensAtLaunch(isComplete: true, isGranted: false),
            "finished setup plus a revoked grant is exactly the update case")
    #expect(OnboardingModel.opensAtLaunch(isComplete: true, isGranted: true) == false,
            "positive control: a working install must not be nagged on every launch")
}

/// Reopening has to land on the step that can fix the problem.
///
/// The step is persisted so a closed guide resumes where it stopped, which
/// is right for someone who walked away mid-setup and wrong here: resuming
/// at the practice step shows "select some text and press the shortcut" to a
/// user whose shortcut cannot read anything.
@Test("reopening for a lost permission starts at the permission step")
@MainActor
func reopeningForALostPermissionRewindsToAccessibility() {
    let model = OnboardingModel(store: makeOnboardingStore(), isAccessibilityTrusted: { true })
    while model.step != .tryIt { model.advance() }
    #expect(model.step == .tryIt, "positive control: the walk reached the last step")

    model.rewindForLostPermission()

    #expect(model.step == .accessibility)
}

/// **Continue must not hand someone a practice step their model cannot run.**
///
/// The model step used to gate only on a transfer being *in flight*, so with
/// nothing downloaded at all the button was enabled and led straight to
/// "select some text and press the shortcut" with no weights on disk. The
/// rewrite then failed on an error about a model the user was never told to
/// fetch.
///
/// The old reasoning was that requiring readiness would strand someone whose
/// download failed. It does not: a failed row shows its error and offers a
/// retry, and Apple's engine needs no download at all, so a Mac with Apple
/// Intelligence has a ready engine the moment it is selected.
@Test("the model step cannot be left until the chosen engine is actually usable")
@MainActor
func continueWaitsForAUsableModel() {
    let ready = OSAllocatedUnfairLock(initialState: false)
    let onboarding = OnboardingModel(
        store: makeOnboardingStore(),
        isAccessibilityTrusted: { true },
        isSelectedEngineReady: { ready.withLock { $0 } }
    )
    onboarding.advance()
    #expect(onboarding.step == .model, "positive control: the permission gate opened")

    #expect(onboarding.canAdvance == false, "nothing downloaded, so there is nowhere to go")
    onboarding.advance()
    #expect(onboarding.step == .model, "and advancing anyway must not move")

    ready.withLock { $0 = true }
    #expect(onboarding.canAdvance, "a ready engine is the whole condition")
    onboarding.advance()
    #expect(onboarding.step == .tryIt)
}

/// A transfer in flight still holds the button, separately from readiness.
/// Letting it through starts the practice hotkey against a half-written
/// model directory, and the hotkey begins a second download of the same
/// weights.
@Test("a download in flight holds Continue even once something is ready")
@MainActor
func continueWaitsForAnInFlightTransfer() {
    let onboarding = OnboardingModel(
        store: makeOnboardingStore(),
        isAccessibilityTrusted: { true },
        isPreparing: { true },
        isSelectedEngineReady: { true }
    )
    onboarding.advance()
    #expect(onboarding.step == .model)
    #expect(onboarding.canAdvance == false)
}

/// **A disabled button must say what would enable it.** Continue going grey
/// on the model step is correct and completely mute: the user cannot tell a
/// download still running from one that failed from a control that is
/// broken, and the three want different actions from them.
///
/// Here rather than in the view because it is a branch, and root `AGENTS.md`
/// §4 — an app-target branch is compiled by nothing `swift test` runs.
@Test("a held Continue names the thing that would release it")
@MainActor
func aHeldContinueSaysWhy() {
    let downloading = OnboardingModel(
        store: makeOnboardingStore(),
        isAccessibilityTrusted: { true },
        isPreparing: { true },
        isSelectedEngineReady: { false }
    )
    downloading.advance()
    #expect(downloading.step == .model, "positive control: the permission gate opened")
    let whileDownloading = downloading.continueHint
    #expect(whileDownloading?.contains("download") == true, "got \(whileDownloading ?? "nil")")

    let empty = OnboardingModel(
        store: makeOnboardingStore(),
        isAccessibilityTrusted: { true },
        isSelectedEngineReady: { false }
    )
    empty.advance()
    // Distinct from the in-flight wording, or "wait" and "act" read the same.
    #expect(empty.continueHint != whileDownloading, "waiting and choosing are different instructions")
    #expect(empty.continueHint?.isEmpty == false)

    let ready = OnboardingModel(
        store: makeOnboardingStore(),
        isAccessibilityTrusted: { true },
        isSelectedEngineReady: { true }
    )
    ready.advance()
    #expect(ready.canAdvance, "positive control: this one really can move")
    #expect(ready.continueHint == nil, "a live button explains itself by working")
}
