import Foundation

/// The guards on the Prompts tab.
///
/// `PromptBuilder.safetyFrame` is deliberately not reachable from Settings at
/// all — it is the prompt-injection frame, and a user-editable frame is not a
/// frame. Every *other* field of a `Preset` is the user's, and each has its own
/// rule because each fails differently when it is empty.
public enum PresetEdit {
    /// The instruction to store, or `nil` when the edit must be refused.
    ///
    /// Emptying it makes `PromptBuilder.build` send the frame, a blank line and
    /// the selected text, leaving the model to invent a task. Whatever it
    /// invents lands in the user's document.
    public static func instruction(from raw: String) -> String? {
        nonEmpty(raw)
    }

    /// The name to store, or `nil` when the edit must be refused.
    ///
    /// The name is the whole of a style's identity in the ⌘⇧I picker: the row
    /// label and the VoiceOver label are both `preset.name`. Emptying it leaves
    /// a row that can only be picked by counting, is announced as nothing, and
    /// is indistinguishable from the next empty one.
    public static func name(from raw: String) -> String? {
        nonEmpty(raw)
    }

    /// The subtitle to store. Never refused.
    ///
    /// The one editable field that is allowed to be empty, and it has to stay
    /// that way: the Add button already creates `subtitle: ""`, so borrowing
    /// the name's rule would make a new style's blank caption unclearable the
    /// moment it had been typed into once. It is a caption under the name, and
    /// an empty caption is one the user chose not to write.
    public static func subtitle(from raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func nonEmpty(_ raw: String) -> String? {
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
