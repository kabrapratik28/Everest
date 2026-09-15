import AppKit
import Foundation
import Testing

@testable import AppCore

private func makeStore() -> UserDefaults {
    UserDefaults(suiteName: "com.kabrapratik.Everest.presence.\(UUID().uuidString)")!
}

/// Records every policy the app was actually asked to take, in order.
@MainActor
private final class PolicyRecorder {
    private(set) var applied: [NSApplication.ActivationPolicy] = []

    func apply(_ policy: NSApplication.ActivationPolicy) { applied.append(policy) }
}

/// `LSUIElement` is `true` in Info.plist, so **every** launch starts at
/// `.accessory` no matter what the user chose last time — verified on macOS
/// 26.6.2: a `Settings`-scene app with `LSUIElement` reports policy `1` in
/// `applicationDidFinishLaunching`. A preference that is only applied when the
/// switch is flipped is therefore a preference that silently turns itself off
/// every morning, and the user has no way to tell it apart from a broken one.
@Test("the app-switcher preference is re-applied at launch, because LSUIElement pins every launch to the menu bar")
@MainActor
func theStoredPreferenceIsAppliedAtLaunch() {
    let store = makeStore()
    let recorder = PolicyRecorder()

    // Yesterday: the user turned it on.
    let before = AppPresence(store: store, setPolicy: { _ in })
    before.showsInDockAndSwitcher = true

    // Today: a fresh process, reading the same defaults.
    let presence = AppPresence(store: store, setPolicy: { recorder.apply($0) })
    #expect(recorder.applied.isEmpty, "constructing it must not move the policy on its own")

    presence.start()

    #expect(recorder.applied == [.regular])
}

/// The switch has to mean something the moment it moves.
///
/// `NSApp.setActivationPolicy` works in both directions at runtime — measured
/// on macOS 26.6.2, `.accessory` → `.regular` → `.accessory` all returned
/// `true` and stuck — so there is nothing to defer and no relaunch to ask for.
/// A settings toggle that needs a restart to do anything reads as a toggle
/// that does nothing.
@Test("flipping the switch moves the activation policy immediately, in both directions")
@MainActor
func flippingThePreferenceAppliesImmediately() {
    let recorder = PolicyRecorder()
    let presence = AppPresence(store: makeStore(), setPolicy: { recorder.apply($0) })

    presence.showsInDockAndSwitcher = true
    presence.showsInDockAndSwitcher = false

    #expect(recorder.applied == [.regular, .accessory])
}
