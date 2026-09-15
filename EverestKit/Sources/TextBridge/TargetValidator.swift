import ApplicationServices

extension AccessibilityReading {
    /// Measured against a real `NSSecureTextField`: role `AXTextField`,
    /// subrole `AXSecureTextField`. Checking the role alone misses it
    /// entirely, which is the empirical reason both slots are tested.
    func isSecure(_ element: AXUIElement) -> Bool {
        let secure = kAXSecureTextFieldSubrole as String
        return subrole(of: element) == secure || role(of: element) == secure
    }
}

/// Three values, not a `Bool`, because "the app stopped answering" is
/// genuinely different from "the selection changed". Validation treats
/// `unknown` as a refusal.
public enum Match: Equatable, Sendable {
    case matches
    case differs
    case unknown
}

/// Proves the world still matches the snapshot. The safety gate.
///
/// There is deliberately **no age limit**. `TargetSnapshot.capturedAt` is
/// never compared against a deadline: a user who has not touched anything for
/// fifteen seconds while a local model works is still entitled to their
/// rewrite. The identity checks are what make the write safe, and a timeout
/// would add a second way to fail while removing none of the ways to be
/// wrong. If a rewrite lands on the wrong text, the bug is in one of the
/// checks below, not in the absence of a clock.
struct TargetValidator {
    let system: SystemProbing
    let accessibility: AccessibilityReading

    enum Refusal: Equatable {
        case notFrontmost
        case focusMoved
        case secure
        case changed
        case unverifiable

        /// The validator knows which of its four identities moved; the
        /// caller should not have to infer that from the sentence.
        var cause: CopyOnlyCause {
            switch self {
            case .notFrontmost, .focusMoved, .changed: .targetChanged
            case .secure: .secureField
            case .unverifiable: .unverifiable
            }
        }

        var reason: String {
            switch self {
            case .notFrontmost: "the target app is no longer frontmost"
            case .focusMoved: "focus moved to another element"
            case .secure: "the target is a secure field"
            case .changed: "the selection changed"
            case .unverifiable: "the target could not be verified"
            }
        }
    }

    /// Any doubt at all resolves to "do not write".
    func validate(_ snapshot: TargetSnapshot) -> Refusal? {
        guard system.frontmostApp()?.pid == snapshot.pid else { return .notFrontmost }

        guard let live = accessibility.focusedElement(pid: snapshot.pid) else {
            return .unverifiable
        }
        // `CFEqual`, not `===`. Two references obtained at different moments
        // for the same interface object are equal but not identical, so
        // pointer comparison would report a mismatch every time and no
        // rewrite would ever be written back.
        guard CFEqual(live, snapshot.element) else { return .focusMoved }

        // Focus can move inside the same element tree while a rewrite is in
        // flight, so this is not a capture-time-only concern.
        guard !accessibility.isSecure(live) else { return .secure }

        switch compare(snapshot, live: live) {
        case .matches: return nil
        case .differs: return .changed
        case .unknown: return .unverifiable
        }
    }

    /// Mirrors the capture chain: the range, then `AXSelectedText`, then
    /// `AXStringForRange`.
    ///
    /// That last fallback is *not* what lets a range-derived capture be
    /// written back — those are refused before the validator is ever
    /// consulted. It survives for two narrower jobs: confirming a normally
    /// captured snapshot whose `AXSelectedText` has gone momentarily empty,
    /// and letting consumption be observed after a paste. In both, the
    /// snapshot's text came from `AXSelectedText`, so a shifted range
    /// produces a mismatch and the conservative refusal, never a false
    /// confirmation.
    func compare(_ snapshot: TargetSnapshot, live element: AXUIElement) -> Match {
        guard let expected = snapshot.range else { return .unknown }
        guard let actual = accessibility.selectedRange(of: element) else { return .unknown }
        guard actual.location == expected.location, actual.length == expected.length else {
            return .differs
        }

        if let selected = accessibility.selectedText(of: element), !selected.isEmpty {
            return selected == snapshot.text ? .matches : .differs
        }
        if let reconstructed = accessibility.string(of: element, in: actual) {
            return reconstructed == snapshot.text ? .matches : .differs
        }
        return .unknown
    }
}
