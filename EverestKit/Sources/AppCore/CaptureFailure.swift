import Foundation
import TextBridge

/// A capture refusal, in words the user can act on.
///
/// Five refusals with five different remedies, so five sentences. Resist
/// folding them into "Everest could not read your selection": that sends the
/// user looking in the wrong place four times out of five — granting a
/// permission they already granted, hunting for a selection they did make,
/// shortening text that was never too long.
///
/// The secure-field sentence earns its second clause specifically. That refusal
/// is the app working exactly as designed, and without being told so the user
/// reads a failure and tries again somewhere less safe.
public enum CaptureFailure {
    /// Takes `any Error` rather than `CaptureError` so the coordinator's catch
    /// has no second branch. `SelectionCoordinator.capture()` is declared with
    /// untyped `throws`, so the compiler cannot prove `CaptureError` is all it
    /// can produce; putting the fallback here keeps the one unprovable case in
    /// the tested lookup instead of in an untested `else` beside the panel call.
    public static func message(for error: any Error) -> String {
        guard let error = error as? CaptureError else {
            return "Everest could not read the selection. Try again, or select the text in a different app."
        }
        return switch error {
        case .accessibilityNotGranted:
            // The second sentence exists because of a real bug report. TCC
            // binds this permission to the code signature, so after the app is
            // replaced the switch stays on while pointing at a signature that
            // no longer exists. Telling that user to "switch Everest on" sends
            // them to do the thing they can see they already did.
            "Everest needs Accessibility permission to read your selection. Open System Settings ▸ Privacy & Security ▸ Accessibility and switch Everest on. If it is already on, remove Everest from that list with the − button and add it again — the permission goes stale when the app is updated."
        case .secureField:
            "That is a secure field. Everest never reads passwords, and nothing was read here."
        case .noSelection:
            "Select the text you want rewritten, then press the shortcut again."
        case let .tooLong(count):
            "That selection is \(grouped(count)) characters. Everest rewrites up to \(grouped(CaptureLimits.maxCharacters)) at a time — select a shorter passage."
        case let .excludedApp(bundleID):
            "Everest is set to stay out of \(bundleID). Remove it from the excluded apps in Settings ▸ Privacy to rewrite here."
        }
    }

    /// The cap is read from `CaptureLimits` rather than written out, so the
    /// sentence cannot drift from the limit it is describing.
    private static func grouped(_ count: Int) -> String {
        count.formatted(.number)
    }
}
