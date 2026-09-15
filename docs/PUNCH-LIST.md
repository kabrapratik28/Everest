# Punch list — small items deferred to integration

Too small to interrupt an agent mid-cycle, too easy to forget. Cleared before
the final commit.

| Item | Where | Why it matters |
|---|---|---|
| Doc comment says "Five refusals with five different remedies, so five sentences" — there are now six | `EverestKit/Sources/AppCore/CaptureFailure.swift:6` | That comment is the thing warning the next person not to fold the messages together. A stale guard-comment undermines the guard. |
| `AppIcon-alt.icns` regenerated, 1.5 MB, referenced by nothing | `Everest/Resources/` | §1: nothing unreferenced. One command to rebuild from `Artwork/` if ever wanted. |
| `Match` is `public`, its only consumer `compare` is internal | `EverestKit/Sources/TextBridge/TargetValidator.swift:16` | Over-broad visibility. Cosmetic; deliberately not touched while the app was being tested. |
| Dead-code sweep was grep-based, not semantic | — | Periphery's Homebrew cask is broken. Grep flags protocol conformances as false positives, so it was reviewed by hand. Labelled honestly rather than implying semantic analysis. |

## Verified non-issues

Recorded so nobody re-investigates them.

- **`Match` / `ProgressStyle` flagged as unreferenced** — false positives. Both are return types whose call sites use `.matches` / `.hidden`, so the type name never reappears.
- **App idling at ~22% CPU** — that was the 2.3 GB model downloading. Idles at 0%.
- **`DVTCoreDeviceCore` plug-in errors and `CoreSimulator is out of date`** on every `xcodebuild` — iOS simulator only, harmless for a macOS target.
