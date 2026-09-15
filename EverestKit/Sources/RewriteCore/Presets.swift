import Foundation

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
}

extension Preset {
    // Fixed, hand-written UUID, not UUID(), for the same reason as
    // builtInStyles below. It no longer shares its instruction with any
    // built-in style: it used to duplicate the picker's "Improve" entry
    // exactly, so the hotkey and the picker's first row did the same thing
    // and one of the choices was spent on it. Proofread holds that slot now.
    // Still its own UUID — the two are independently user-editable
    // AppSettings fields. See RewriteCore/AGENTS.md.
    //
    // The last sentence is load-bearing: without it a 4B model rewrites text
    // that was already fine, which is the common case for the broad default.
    public static var quickImprove: Preset {
        Preset(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "Improve",
            subtitle: "clear + correct",
            instruction: "Improve the writing for correctness, clarity, concision, and natural flow. Fix grammar, spelling, punctuation, awkward phrasing, and unnecessary repetition. Preserve the writer’s meaning, voice, language, formatting, and level of detail. Do not make it more formal or casual. If it is already clear, change as little as possible."
        )
    }

    // Fixed, hand-written UUIDs, not UUID(). Minting a fresh UUID on every
    // access would break Codable round-tripping through AppSettings and
    // SwiftUI list identity for the style picker. See RewriteCore/AGENTS.md.
    //
    // Six, and these six: they cover correction level, tone, length and
    // readability without overlapping. Formal/Casual duplicate
    // Professional/Friendly, Confident belongs inside Professional,
    // Persuasive and Academic are narrow enough to be custom styles,
    // Summarize is not a faithful rewrite, and Translate needs a
    // destination-language control rather than another vague preset.
    //
    // Each instruction names what to preserve as well as what to change. A
    // tone instruction on its own drifts: "professional" alone turns verbose
    // and corporate and strengthens tentative claims, "friendly" alone
    // produces greetings and emoji the original never implied, and "expand"
    // alone invites invented facts.
    public static var builtInStyles: [Preset] {
        [
            Preset(
                id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                name: "Proofread",
                subtitle: "corrections only",
                instruction: "Correct spelling, grammar, punctuation, capitalization, and obvious typos. Make only changes required for correctness; otherwise preserve the wording, structure, tone, and formatting."
            ),
            Preset(
                id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                name: "Professional",
                subtitle: "polished + confident",
                instruction: "Rewrite in a clear, polished, professional tone. Keep it natural and concise, not stiff or corporate. Preserve the original meaning, level of certainty, requests, commitments, and factual details."
            ),
            Preset(
                id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                name: "Friendly",
                subtitle: "warm + natural",
                instruction: "Rewrite in a warm, natural, conversational tone. Keep it clear and respectful without adding greetings, emojis, exclamation marks, enthusiasm, or familiarity that the original does not imply."
            ),
            Preset(
                id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                name: "Concise",
                subtitle: "shorter + direct",
                instruction: "Make the text shorter and more direct. Remove filler and repetition, combine redundant sentences, and simplify wording. Preserve every essential fact, qualification, request, commitment, and action item."
            ),
            Preset(
                id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
                name: "Expand",
                subtitle: "clarify + develop",
                instruction: "Expand only enough to make the existing meaning, reasoning, and context clearer. Add useful transitions or explanation supported by the text. Do not invent examples, evidence, facts, commitments, or conclusions."
            ),
            Preset(
                id: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!,
                name: "Simplify",
                subtitle: "plain + readable",
                instruction: "Rewrite in plain, easy-to-read language. Shorten complex sentences and replace unnecessary jargon with familiar words while preserving technical terms, meaning, tone, and important detail. Do not make the text childish."
            ),
        ]
    }
}
