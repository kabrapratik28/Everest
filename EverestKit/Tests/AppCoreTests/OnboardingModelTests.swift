import Synchronization
import Testing

@testable import AppCore

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
    let onboarding = OnboardingModel(isAccessibilityTrusted: { trusted.withLock { $0 } })

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
    let onboarding = OnboardingModel(isAccessibilityTrusted: { true })

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
