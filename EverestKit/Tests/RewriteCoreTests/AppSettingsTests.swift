import Testing
import Foundation
@testable import RewriteCore

@Test("AppSettings round-trips engineID, quickImprove, styles, and excludedBundleIDs through an injected store")
@MainActor
func appSettingsRoundTripsThroughInjectedStore() {
    let suiteName = "com.kabrapratik.Everest.tests.\(UUID().uuidString)"
    let store = UserDefaults(suiteName: suiteName)!
    defer { store.removePersistentDomain(forName: suiteName) }

    let customPreset = Preset(name: "Custom", subtitle: "custom", instruction: "Custom instruction")
    let customStyles = [customPreset]
    let customExcluded = ["com.example.SomeApp"]

    let settings = AppSettings(store: store)
    settings.engineID = .qwen30B
    settings.quickImprove = customPreset
    settings.styles = customStyles
    settings.excludedBundleIDs = customExcluded

    // A second instance reading the same store should see what the first wrote,
    // not just in-memory state on the first instance.
    let reloaded = AppSettings(store: store)
    #expect(reloaded.engineID == .qwen30B)
    #expect(reloaded.quickImprove == customPreset)
    #expect(reloaded.styles == customStyles)
    #expect(reloaded.excludedBundleIDs == customExcluded)
}

/// Review defaults on, because a rewrite nobody has seen should not reach a
/// document by default; once turned off it must stay off across launches,
/// which `flag(_:_:default:)` exists to guarantee. The view choice and the
/// panel's place are remembered the same way.
@Test("review defaults on and stays off once turned off; the view and the panel's place survive a relaunch")
@MainActor
func reviewSettingsDefaultAndPersist() {
    let suiteName = "com.kabrapratik.Everest.tests.\(UUID().uuidString)"
    let store = UserDefaults(suiteName: suiteName)!
    defer { store.removePersistentDomain(forName: suiteName) }

    let fresh = AppSettings(store: store)
    #expect(fresh.reviewsBeforeReplacing)
    #expect(fresh.showsChanges == false)
    #expect(fresh.panelAnchor == nil)

    fresh.reviewsBeforeReplacing = false
    fresh.showsChanges = true
    fresh.panelAnchor = PanelAnchor(x: 0.8, y: 0.25, pinsTop: false)

    let relaunched = AppSettings(store: store)
    #expect(relaunched.reviewsBeforeReplacing == false)
    #expect(relaunched.showsChanges)
    #expect(relaunched.panelAnchor == PanelAnchor(x: 0.8, y: 0.25, pinsTop: false))
}

/// The review pane's keys are the user's to choose, from lists short enough
/// that no choice can break the pane, and the choice survives a relaunch.
@Test("the review pane's keys default to ↩ and ⌘D and survive a relaunch")
@MainActor
func reviewKeysDefaultAndPersist() {
    let suiteName = "com.kabrapratik.Everest.tests.\(UUID().uuidString)"
    let store = UserDefaults(suiteName: suiteName)!
    defer { store.removePersistentDomain(forName: suiteName) }

    let fresh = AppSettings(store: store)
    #expect(fresh.reviewKeys == ReviewKeys(replace: .returnKey, changes: .commandD))

    fresh.reviewKeys = ReviewKeys(replace: .commandReturn, changes: .tab)
    #expect(AppSettings(store: store).reviewKeys == ReviewKeys(replace: .commandReturn, changes: .tab))
}
