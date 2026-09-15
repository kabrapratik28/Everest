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
            case .capabilities: capabilities
            case .model: modelStep
            case .tryIt: tryIt
            }

            Spacer()

            HStack {
                Spacer()
                if model.step == .tryIt {
                    Button("Done", action: finish).keyboardShortcut(.defaultAction)
                } else {
                    Button("Continue") { model.advance() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.step == .accessibility && !isGranted)
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
        }
    }

    private var capabilities: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What Everest can do where").font(.title2).bold()
            Text(
                """
                Reading your selection works almost everywhere. Writing it back does not, \
                because some places have no editable text behind the selection. Everest hands \
                you the clipboard there instead of pretending.
                """
            )
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Where").bold()
                    Text("Read").bold()
                    Text("Replace").bold()
                }
                ForEach(OnboardingModel.capabilities) { row in
                    GridRow {
                        Text(row.context)
                        Text(describe(row.capture))
                        Text(describe(row.replace)).foregroundStyle(colour(row.replace))
                    }
                }
            }
            .font(.callout)

            Text("Password and secure fields are never read. Everest refuses before it looks.")
                .font(.callout)
                .bold()
            // Not optional, and the wording is pinned by a test in `AppCore`.
            // A user who reads the excluded-app list as the protection will
            // add their bank to it, get nothing, and never find out.
            Text(OnboardingModel.exclusionCaveat)
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
                        Text(row.spec.displayName).font(.headline)
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

    private func describe(_ capture: OnboardingModel.CaptureAbility) -> String {
        switch capture {
        case .yes: "Yes"
        case .usually: "Usually"
        case .never: "Never"
        }
    }

    /// Words as well as colour. A green tick and a red cross at this size are
    /// the same grey glyph to one man in twelve, so the column says which.
    private func describe(_ replace: OnboardingModel.ReplaceAbility) -> String {
        switch replace {
        case .inPlace: "In place"
        case .copyOnly: "Copy only"
        case .refused: "Refused"
        }
    }

    private func colour(_ replace: OnboardingModel.ReplaceAbility) -> Color {
        switch replace {
        case .inPlace: .primary
        case .copyOnly: .secondary
        case .refused: .secondary
        }
    }
}
