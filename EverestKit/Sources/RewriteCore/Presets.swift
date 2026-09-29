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
    // The last sentence matters most: without it a 4B model rewrites text
    // that was already fine, which is the common case for the broad default.
    public static var quickImprove: Preset {
        Preset(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "Improve",
            subtitle: "clear + correct",
            instruction: "Fix grammar, spelling, punctuation and capitalization, and smooth out awkward, wordy or repetitive phrasing so it reads clearly. Keep the writer's voice and level of detail. If it already reads well, change as little as possible."
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
                instruction: "Fix every spelling, grammar, punctuation and capitalization mistake, and every typo or wrong word. Apart from the number and em dash rules above, don't reword, shorten or restyle anything."
            ),
            Preset(
                id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                name: "Professional",
                subtitle: "clear + polished",
                instruction: "Make it clear, direct and professional, the way a capable colleague would write it: not stiff, not corporate, and no more certain than the original. Keep every request, commitment and detail."
            ),
            Preset(
                id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                name: "Friendly",
                subtitle: "warm + natural",
                instruction: "Make it warm, natural and conversational. Keep the meaning, details and level of familiarity. Don't add new points, greetings, emoji, exclamation marks or enthusiasm the original doesn't have."
            ),
            Preset(
                id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                name: "Concise",
                subtitle: "shorter + direct",
                instruction: "Make it shorter and more direct by cutting filler and repetition. Keep the writer's tone and every fact, qualification, request, commitment and action item."
            ),
            Preset(
                id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
                name: "Expand",
                subtitle: "explain + clarify",
                instruction: "Add only enough explanation to make the ideas already there clearer. Keep the tone, facts, uncertainty and scope. Don't invent examples, evidence, claims, commitments or conclusions."
            ),
            Preset(
                id: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!,
                name: "Simplify",
                subtitle: "plain + readable",
                instruction: "Make it easier to read with everyday words and shorter sentences. Keep the meaning, tone, important details and necessary technical terms. Don't make it childish."
            ),
        ]
    }
}
