import Foundation

/// The one guard on the Prompts tab.
///
/// `PromptBuilder.safetyFrame` is deliberately not reachable from Settings at
/// all — it is the prompt-injection frame, and a user-editable frame is not a
/// frame. `Preset.instruction` is the only editable string, and the only thing
/// that can go wrong with it is emptying it: `PromptBuilder.build` would then
/// send the frame, a blank line, and the selected text, leaving the model to
/// invent a task. Whatever it invents lands in the user's document.
public enum PresetEdit {
    /// The instruction to store, or `nil` when the edit must be refused.
    public static func instruction(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// The one guard on the Privacy tab.
///
/// The excluded-app list is the only mitigation for the residual secure-field
/// gap in apps that expose no accessibility tree, so its contents have to
/// mean something. A blank entry matches nothing and sits there looking like
/// protection. A duplicate makes removal look broken: the user deletes the row
/// they can see and the app is still excluded by the one they cannot.
public enum ExclusionEdit {
    /// The new list, or `nil` when the entry must be refused.
    ///
    /// Case-insensitive, matching `SelectionCoordinator.isExcluded`, so
    /// `COM.1Password.1Password` is the same entry as `com.1password.1password`
    /// and adding it twice is refused rather than silently doubling a control
    /// the user cannot then fully remove.
    public static func add(_ raw: String, to existing: [String]) -> [String]? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !existing.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame })
        else { return nil }
        return existing + [trimmed]
    }
}
