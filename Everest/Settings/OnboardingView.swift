import Combine
import AppCore
import RewriteCore
import SwiftUI

/// First run: permission, then what the app can and cannot do, then the
/// model, then one real rewrite.
///
/// Every rule is in `OnboardingModel`; this is layout and one timer.
struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var models: ModelSettingsModel
    let requestAccessibility: () -> Void
    /// Rendered from the live binding, never a literal. See `ShortcutCopy`.
    let shortcutText: @MainActor (Hotkey) -> String?
    let collisionCaution: @MainActor () -> String?
    /// Last, because a memberwise init takes arguments in declaration order
    /// and the call site groups the three that supply text before the one
    /// that ends the flow.
    let finish: () -> Void

    /// The permission is granted in System Settings while this window is open,
    /// so the button has to light up without anything happening in here. The
    /// shortcut copy rides the same tick, so re-recording a binding in another
    /// window cannot leave this screen naming the old one.
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var isGranted = false
    @State private var instruction = ""
    @State private var caution: String?
    @State private var practice = "we was hoping to get your thoughts sometime this week"

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            switch model.step {
            case .accessibility: permission
            case .model: modelStep
            case .tryIt: tryIt
            }

            Spacer()

            HStack(alignment: .firstTextBaseline) {
                // A grey button with nothing beside it was the dead end:
                // pressing Continue with no model did nothing and said
                // nothing. The wording is `AppCore`'s, next to the rule that
                // decides the button, so the two cannot drift apart.
                if let hint = model.continueHint {
                    Text(hint).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if model.step == .tryIt {
                    Button("Done", action: finish).keyboardShortcut(.defaultAction)
                } else {
                    Button("Continue") { model.advance() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canAdvance)
                }
            }
        }
        .padding(28)
        .onAppear { refresh() }
        .onReceive(poll) { _ in refresh() }
    }

    private func refresh() {
        isGranted = model.isGranted
        instruction = ShortcutCopy.tryItInstruction(quickImprove: shortcutText(.quickImprove))
        caution = collisionCaution()
    }

    private var permission: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Everest needs Accessibility access").font(.title2).bold()
            Text(
                """
                That is how it reads the text you have selected and puts the rewrite back. \
                It is the whole feature, so there is nothing useful past this step without it.
                """
            )
            Button("Open System Settings…", action: requestAccessibility)
            Label(
                isGranted ? "Granted" : "Waiting for permission",
                systemImage: isGranted ? "checkmark.circle" : "clock"
            )
            .foregroundStyle(isGranted ? Color.green : .secondary)

            // Was on the removed capability screen, and this is the honest
            // place for it: the user is being asked for permission to read
            // any text they select, so what Everest refuses to read belongs
            // in the same breath as the ask, not a screen later.
            //
            // Pinned by a test in `AppCore`, and deliberately not absolute:
            // the subrole refusal needs an element and the secure-input flag
            // needs the host to set it, so an app exposing neither is a case
            // the chain has no way to recognise. "Never read" was a
            // measurement of one browser standing in for every app forever.
            Text(OnboardingModel.passwordPromise)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var modelStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose a model").font(.title2).bold()
            Text("It runs on this Mac. Nothing you rewrite is sent anywhere.")

            ForEach(models.rows) { row in
                HStack(alignment: .top) {
                    VStack(alignment: .leading) {
                        HStack(spacing: 6) {
                            Text(row.spec.displayName).font(.headline)
                            if row.spec.isDefault { RecommendedBadge() }
                        }
                        Text(row.spec.blurb).font(.callout).foregroundStyle(.secondary)
                        // Both of these were missing, and together they were
                        // the dead end: the default model is selected and
                        // absent on every new Mac, so the only control said
                        // "In use", was disabled, and nothing on the screen
                        // mentioned that 2.3 GB had yet to arrive.
                        Text(row.installSummary).font(.caption).foregroundStyle(.secondary)
                        if let failure = models.downloadFailure[row.spec.id] {
                            Text(failure).font(.caption).foregroundStyle(.red)
                        }
                    }
                    Spacer()
                    if let progress = models.downloadProgress[row.spec.id] {
                        ProgressView(value: progress).frame(width: 120)
                    } else {
                        VStack(alignment: .trailing) {
                            // Keyed on `needsDownload`, not on selection, so
                            // the model in use can still be fetched.
                            if row.needsDownload {
                                Button(row.isSelected ? "Download" : "Use and download") {
                                    models.select(row.spec.id)
                                    Task { await models.download(row.spec) }
                                }
                            } else if row.isSelected {
                                Text("In use").foregroundStyle(.secondary)
                            } else {
                                // Through `select`, never by assigning
                                // `engineID`: the rows carry their own
                                // `isSelected`, and a second way to move the
                                // setting leaves that mark on the model the
                                // user just replaced.
                                // `installSummary` above carries the reason
                                // when this Mac has too little memory.
                                Button("Use this") { models.select(row.spec.id) }
                                    .disabled(!row.isEligible)
                            }
                        }
                    }
                }
            }
        }
        .task { await models.refresh() }
    }

    private var tryIt: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Try one rewrite").font(.title2).bold()
            // Never a written-out glyph. The defaults moved once and this
            // screen went on telling new users to press a key that did
            // nothing; the sentence is built in `AppCore` from whatever is
            // bound at this moment, and re-read on the poll below so
            // re-recording mid-setup cannot strand it.
            Text(instruction)
            // `@State`, not `.constant` — the step says "type something
            // below" and the field used to be read-only, so the one screen
            // that proves the hotkey works could not be used to prove it.
            TextEditor(text: $practice)
                .frame(height: 90)
                .border(.separator)
                .accessibilityLabel("Practice field")
            VStack(alignment: .leading, spacing: 4) {
                if let caution {
                    Text(caution)
                }
                Text("You can change both shortcuts in Settings ▸ General.")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }
}
