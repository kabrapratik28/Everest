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
    // builtInStyles below. Shares its instruction text with builtInStyles'
    // "Improve" entry on purpose, but deliberately has its own UUID: they are
    // two independently user-editable AppSettings fields. See RewriteCore/AGENTS.md.
    public static var quickImprove: Preset {
        Preset(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "Improve",
            subtitle: "grammar + tighten",
            instruction: "Fix grammar, spelling, and awkward phrasing. Tighten wordy sentences. Keep the meaning and tone the same."
        )
    }

    // Fixed, hand-written UUIDs, not UUID(). Minting a fresh UUID on every
    // access would break Codable round-tripping through AppSettings and
    // SwiftUI list identity for the style picker. See RewriteCore/AGENTS.md.
    public static var builtInStyles: [Preset] {
        [
            Preset(
                id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                name: "Improve",
                subtitle: "grammar + tighten",
                instruction: "Fix grammar, spelling, and awkward phrasing. Tighten wordy sentences. Keep the meaning and tone the same."
            ),
            Preset(
                id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                name: "Professional",
                subtitle: "formal tone",
                instruction: "Rewrite in a clear, professional tone suitable for a workplace audience."
            ),
            Preset(
                id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                name: "Friendly",
                subtitle: "warmer, casual",
                instruction: "Rewrite in a warm, casual, conversational tone."
            ),
            Preset(
                id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                name: "Concise",
                subtitle: "shorter, punchier",
                instruction: "Make this significantly shorter and more direct without losing key information."
            ),
            Preset(
                id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
                name: "Expand",
                subtitle: "add detail",
                instruction: "Expand this with more supporting detail and clarity while preserving the original meaning."
            ),
        ]
    }
}
