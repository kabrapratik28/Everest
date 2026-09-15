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
