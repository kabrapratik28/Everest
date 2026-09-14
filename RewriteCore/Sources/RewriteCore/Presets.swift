import Foundation

/// A named rewrite configuration: display text for pickers, plus the
/// user-editable `instruction`. `instruction` is the *only* user-facing
/// prompt content; see AGENTS.md for why the safety frame in
/// `PromptBuilder` is kept out of this struct entirely.
public struct Preset: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var subtitle: String
    public var instruction: String

    public init(id: UUID = UUID(), name: String, subtitle: String, instruction: String) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.instruction = instruction
    }

    /// Shared instruction text for the "Improve" preset, used by both
    /// `quickImprove` and the first entry of `builtInStyles`. Kept as one
    /// constant so the two never drift apart by accident; they still carry
    /// distinct identities (see below) because they are independently
    /// user-editable settings.
    private static let improveInstruction =
        "Improve clarity and flow, tighten wordy phrasing, and correct grammar. Preserve the author's voice and intent."

    /// The ⌘I default: one saved prompt, no picker. Fixed UUID so this
    /// value's identity is stable across launches and Codable round-trips
    /// through `AppSettings`; see AGENTS.md.
    public static var quickImprove: Preset {
        Preset(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!,
            name: "Improve",
            subtitle: "grammar + tighten",
            instruction: improveInstruction
        )
    }

    /// The ⌘⇧I picker list. Order is display order. Each entry has a fixed
    /// UUID for the same reason `quickImprove` does.
    public static var builtInStyles: [Preset] {
        [
            Preset(
                id: UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!,
                name: "Improve",
                subtitle: "grammar + tighten",
                instruction: improveInstruction
            ),
            Preset(
                id: UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!,
                name: "Professional",
                subtitle: "polished, formal tone",
                instruction: "Rewrite in a polished, professional tone suitable for a workplace audience. Remove slang and casual filler. Keep it direct and courteous."
            ),
            Preset(
                id: UUID(uuidString: "00000000-0000-0000-0000-0000000000B3")!,
                name: "Concise",
                subtitle: "cut to the essentials",
                instruction: "Cut this down to its essential meaning. Remove redundancy, hedging, and filler words. Prefer short sentences."
            ),
            Preset(
                id: UUID(uuidString: "00000000-0000-0000-0000-0000000000B4")!,
                name: "Friendly",
                subtitle: "warmer, more casual tone",
                instruction: "Rewrite in a warmer, more casual, approachable tone, as if talking to a friend, while keeping the meaning intact."
            ),
            Preset(
                id: UUID(uuidString: "00000000-0000-0000-0000-0000000000B5")!,
                name: "Grammar Only",
                subtitle: "fix errors, nothing else",
                instruction: "Fix only spelling, grammar, and punctuation errors. Do not change word choice, tone, structure, or length otherwise."
            ),
        ]
    }
}
