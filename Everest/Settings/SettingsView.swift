import Combine
import AppCore
import KeyboardShortcuts
import RewriteCore
import ServiceManagement
import SwiftUI

/// Four tabs. Every rule they enforce lives in `AppCore`; this is layout.
struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var models: ModelSettingsModel
    @ObservedObject var presence: AppPresence
    let isAccessibilityTrusted: () -> Bool
    /// Sparkle's `SUEnableAutomaticChecks`, bound straight through to the
    /// updater rather than to a stored copy — see `EverestApp`.
    let automaticUpdateChecks: Binding<Bool>
    /// The caution for the Quick Improve binding *as it stands now*, or nil.
    /// A closure rather than a value because the recorder on this very screen
    /// can change the answer while it is open.
    let collisionCaution: @MainActor () -> String?
    /// Which character the binding costs, or nil. Separate from the caution
    /// because it is information, not a problem — see `ShortcutNotice`.
    let shortcutCostNote: @MainActor () -> String?

    var body: some View {
        TabView {
            GeneralTab(
                settings: settings,
                presence: presence,
                isAccessibilityTrusted: isAccessibilityTrusted,
                collisionCaution: collisionCaution,
                shortcutCostNote: shortcutCostNote
            )
            .tabItem { Label("General", systemImage: "gearshape") }
            ModelTab(models: models)
                .tabItem { Label("Model", systemImage: "cpu") }
            PromptsTab(settings: settings)
                .tabItem { Label("Prompts", systemImage: "text.quote") }
            PrivacyTab(settings: settings, automaticUpdateChecks: automaticUpdateChecks)
                .tabItem { Label("Privacy", systemImage: "lock") }
        }
        .frame(width: 560, height: 460)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var presence: AppPresence
    let isAccessibilityTrusted: () -> Bool
    let collisionCaution: @MainActor () -> String?
    let shortcutCostNote: @MainActor () -> String?

    @State private var isTrusted = false
    @State private var caution: String?
    @State private var costNote: String?
    @State private var launchesAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?

    /// Re-read while the window is open. The user grants the permission in
    /// System Settings, in another process, and a value sampled once would
    /// keep saying "Not granted" after they had granted it.
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("Shortcuts") {
                KeyboardShortcuts.Recorder("Quick Improve", name: .quickImprove)
                KeyboardShortcuts.Recorder("Choose Style", name: .chooseStyle)
                // Shown only while the binding in the box above actually
                // collides. This used to state flatly that Everest uses ⌘I;
                // the default then moved twice and the sentence became
                // simply false, which is the whole reason no glyph is written
                // down anywhere any more. Re-read on the poll below, because
                // the recorder that changes the answer is on this screen.
                if let caution {
                    Text(caution).font(.callout).foregroundStyle(.secondary)
                }
                // Plain secondary text, deliberately not styled as the
                // caution above: every printable binding costs a character,
                // the default included, and that cost is why `⌥R` was chosen
                // over `⌘I`. Dressed as a warning it would report the reason
                // for the choice as a fault — and one that fires on the
                // default teaches people to skip the two that matter.
                if let costNote {
                    Text(costNote).font(.callout).foregroundStyle(.secondary)
                }
            }

            Section("Accessibility") {
                LabeledContent("Permission") {
                    Label(
                        isTrusted ? "Granted" : "Not granted",
                        systemImage: isTrusted ? "checkmark.circle" : "exclamationmark.triangle"
                    )
                }
                Button("Open System Settings…") { AppDelegate.openAccessibilitySettings() }
                Text("Everest cannot read or replace a selection without this.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Startup") {
                Toggle("Launch Everest at login", isOn: $launchesAtLogin)
                    .onChange(of: launchesAtLogin) { _, wanted in setLoginItem(wanted) }
                if let loginItemError {
                    Text(loginItemError).font(.callout).foregroundStyle(.red)
                }
            }

            // All three sentences are `ReplacementCopy`, pinned by tests in
            // `AppCore`. The history caveat especially: `TransientType` is a
            // convention managers opt into, and a toggle implying macOS
            // enforces it would be the Privacy screen's "Nowhere" again.
            Section("Replacing text") {
                Toggle("Replace automatically", isOn: $settings.replacesAutomatically)
                Text(ReplacementCopy.autoReplaceExplanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Toggle(
                    "Keep rewrites out of clipboard history",
                    isOn: $settings.keepsOutOfClipboardHistory
                )
                Text(ReplacementCopy.historyCaveat)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                // Only for the one combination that leaves the rewrite
                // nowhere else. `retrievalNote` decides that, not this view.
                if let note = ReplacementCopy.retrievalNote(
                    autoReplace: settings.replacesAutomatically,
                    keepOutOfHistory: settings.keepsOutOfClipboardHistory
                ) {
                    Text(note).font(.callout).foregroundStyle(.secondary)
                }
            }

            // The label names the Dock as well as the switcher because macOS
            // does not separate them: ⌘Tab membership *is* the regular
            // activation policy, which is also what puts an icon in the Dock.
            // A switch labelled only "Show in ⌘Tab" would deliver something
            // the user did not ask for and could not find the switch for.
            Section("Appearance") {
                Toggle("Show Everest in the Dock and app switcher", isOn: $presence.showsInDockAndSwitcher)
                Text("Off, Everest lives only in the menu bar. There is no way to appear in ⌘Tab without also appearing in the Dock.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { refresh() }
        .onReceive(poll) { _ in refresh() }
    }

    private func refresh() {
        isTrusted = isAccessibilityTrusted()
        caution = collisionCaution()
        costNote = shortcutCostNote()
    }

    /// `SMAppService` throws rather than returning a result, and the toggle
    /// has already moved by the time it does. Putting it back and saying why
    /// is the only honest option: a switch that silently springs back reads as
    /// a broken control.
    private func setLoginItem(_ wanted: Bool) {
        do {
            if wanted {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemError = nil
        } catch {
            launchesAtLogin = SMAppService.mainApp.status == .enabled
            loginItemError = "macOS refused the change. Check Login Items in System Settings."
        }
    }
}

// MARK: - Model

private struct ModelTab: View {
    @ObservedObject var models: ModelSettingsModel

    @State private var sample = "we was hoping to maybe get your thoughts on the deck sometime this week if thats ok"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(models.rows) { row in
                ModelRow(row: row, models: models)
                Divider()
            }

            Text("Try it")
                .font(.headline)
            HStack(alignment: .top, spacing: 12) {
                TextEditor(text: $sample)
                    .font(.body)
                    .frame(minHeight: 80)
                    .accessibilityLabel("Sample text")
                ScrollView {
                    Text(models.testOutput ?? models.testFailure ?? "The rewrite appears here.")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(models.testOutput == nil ? .secondary : .primary)
                }
                .frame(minHeight: 80)
                .accessibilityLabel("Rewritten sample")
            }
            Button("Rewrite the sample") {
                Task { await models.runTest(on: sample) }
            }

            Spacer()
        }
        .padding()
        .task { await models.refresh() }
    }
}

/// The row *is* the radio button.
///
/// It used to draw one and put the choosing on a "Use" button beside it, so
/// the control that looked like a radio button was a picture and the control
/// that worked was somewhere else. A plain-styled `Button` over the whole
/// label keeps the two together, and carries the traits that make it a radio
/// button to VoiceOver and a stop on the keyboard tour rather than a picture
/// that happens to be clickable.
/// Marks the catalogue default. `ModelSpec.isDefault` already decides which
/// one that is and `EngineEligibility.resolved` already falls back to it, so
/// this adds no concept: it says out loud what the code was doing silently.
///
/// Worth saying on the model step in particular. Three engines with sizes
/// from 2.3 GB to 17.2 GB is a choice a first-time user has no basis to
/// make, and the smallest one is the right answer for almost everybody.
struct RecommendedBadge: View {
    var body: some View {
        Text("Recommended")
            .font(.caption2).bold()
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.15), in: Capsule())
            .foregroundStyle(Color.accentColor)
            .accessibilityLabel("Recommended")
    }
}

private struct ModelRow: View {
    let row: ModelSettingsModel.Row
    @ObservedObject var models: ModelSettingsModel

    var body: some View {
        HStack(alignment: .top) {
            Button { models.select(row.spec.id) } label: {
                HStack(alignment: .top) {
                    Image(systemName: row.isSelected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(row.isSelected ? Color.accentColor : .secondary)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(row.spec.displayName).font(.headline)
                            if row.spec.isDefault { RecommendedBadge() }
                        }
                        // The blurb inline, which is the only place a user
                        // learns that Apple's engine has a content filter they
                        // cannot switch off before it cuts a rewrite in half.
                        Text(row.spec.blurb).font(.callout).foregroundStyle(.secondary)
                        Text(row.installSummary).font(.caption).foregroundStyle(.secondary)
                        // A download that stopped has to say so here, or the
                        // bar just vanishes and the user retries the same
                        // failure with nothing to go on.
                        if let failure = models.downloadFailure[row.spec.id] {
                            Text(failure).font(.caption).foregroundStyle(.red)
                        }
                    }

                    // The blurb and the empty space beside it are part of the
                    // target: a radio button whose label is not clickable is
                    // the complaint this replaced.
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Still listed, and `installSummary` says why it is off. Hiding
            // the row sends someone who read about the model hunting for it,
            // and greying one out with no reason is its own dead end.
            // `isEligible`, not `fitsInMemory`: an engine that is available
            // nowhere is no more choosable than one that does not fit.
            .disabled(!row.isEligible)
            .accessibilityLabel(
                "\(row.spec.displayName). \(row.spec.isDefault ? "Recommended. " : "")\(row.spec.blurb). \(row.installSummary)"
            )
            .accessibilityAddTraits(row.isSelected ? [.isSelected] : [])
            .accessibilityHint("Rewrites with this model")

            if let progress = models.downloadProgress[row.spec.id] {
                ProgressView(value: progress).frame(width: 120)
            } else {
                VStack(alignment: .trailing) {
                    // `row.needsDownload`, never "is it selected" — they are
                    // different facts, and the default engine on a new Mac is
                    // both selected and absent.
                    if row.needsDownload {
                        Button("Download") { Task { await models.download(row.spec) } }
                    }
                    Button("Delete", role: .destructive) {
                        Task { try? await models.delete(row.spec) }
                    }
                    .disabled(!models.canDelete(row.spec))
                }
            }
        }
    }
}

// MARK: - Prompts

private struct PromptsTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            // Instruction only, and deliberately. Quick Improve has no row in
            // the Choose Style picker — which lists `settings.styles` — so its
            // name and subtitle render nowhere in the app. Fields for them
            // were built and removed: one you can type in that changes
            // nothing on screen reads as a bug, which is worse than its
            // absence. Styles keep all three, because the picker shows them.
            //
            // `PromptBuilder.safetyFrame` is the field that is not the user's
            // at all, and it is not reachable from this screen and must never
            // become so: it is the prompt-injection frame, and a user-editable
            // frame is not a frame. See RewriteCore/AGENTS.md.
            Section("Quick Improve") {
                PresetField(
                    "Instruction",
                    text: $settings.quickImprove.instruction,
                    validate: PresetEdit.instruction(from:),
                    lineLimit: 2...6
                )
                Button("Reset to default") { settings.resetQuickImprove() }
            }

            // Explicit move and remove buttons rather than `onMove`/`onDelete`.
            // Those are `List` affordances; inside a macOS `Form` they either
            // do nothing or need an `EditButton` that has no macOS equivalent,
            // and "reorder" is in the requirements.
            Section("Styles") {
                ForEach(Array($settings.styles.enumerated()), id: \.element.id) { index, $style in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            PresetField("Name", text: $style.name, validate: PresetEdit.name(from:))
                            Button { move(index, by: -1) } label: { Image(systemName: "arrow.up") }
                                .disabled(index == 0)
                                .accessibilityLabel("Move \(style.name) up")
                            Button { move(index, by: 1) } label: { Image(systemName: "arrow.down") }
                                .disabled(index == settings.styles.count - 1)
                                .accessibilityLabel("Move \(style.name) down")
                            // By id, not by the captured `index`. The row
                            // closure outlives the array it indexes: after a
                            // delete the list is shorter while a retained
                            // closure still holds the old position, and
                            // `remove(at:)` traps on an index that no longer
                            // exists. `removeAll(where:)` on identity cannot.
                            Button(role: .destructive) {
                                let id = style.id
                                settings.styles.removeAll { $0.id == id }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .accessibilityLabel("Delete \(style.name)")
                        }
                        PresetField(
                            "Subtitle",
                            text: $style.subtitle,
                            validate: { PresetEdit.subtitle(from: $0) as String? }
                        )
                        PresetField(
                            "Instruction",
                            text: $style.instruction,
                            validate: PresetEdit.instruction(from:),
                            lineLimit: 2...6
                        )
                    }
                }

                Button("Add style") {
                    settings.styles.append(
                        Preset(name: "New style", subtitle: "", instruction: "Rewrite this.")
                    )
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Both ends are checked, not just the destination.
    ///
    /// `index` is captured by a row closure that can outlive the array it
    /// indexes — delete a style and the list is shorter while the old
    /// position is still held — so `swapAt` can trap on the *source* as
    /// readily as on the target.
    private func move(_ index: Int, by offset: Int) {
        let destination = index + offset
        guard settings.styles.indices.contains(index),
              settings.styles.indices.contains(destination)
        else { return }
        settings.styles.swapAt(index, destination)
    }
}

/// One editable field of a `Preset`, which never commits a value its own rule
/// refuses.
///
/// The rules are `PresetEdit`, in `AppCore`, where they have tests — and they
/// differ per field, which is why the rule is passed in rather than assumed: a
/// blank instruction leaves the model to invent a task that lands in the
/// user's document, a blank name leaves an unpickable row in the style picker,
/// and a blank subtitle is simply a caption nobody wrote.
///
/// The draft is kept separately from the stored value so trimming does not
/// fight the user's typing: a trailing space stays visible while they are
/// mid-word, and emptying a field whose rule refuses blanks leaves the last
/// good value stored rather than saving nothing.
private struct PresetField: View {
    private let prompt: String
    @Binding private var value: String
    /// `nil` refuses the edit and leaves the stored value alone.
    private let validate: (String) -> String?
    private let lineLimit: ClosedRange<Int>

    @State private var draft = ""

    init(
        _ prompt: String,
        text: Binding<String>,
        validate: @escaping (String) -> String?,
        lineLimit: ClosedRange<Int> = 1...1
    ) {
        self.prompt = prompt
        _value = text
        self.validate = validate
        self.lineLimit = lineLimit
    }

    /// Caption above, bordered field below — and the caption is why the
    /// field is wrapped at all.
    ///
    /// Two problems, one shape. A `TextField` in a macOS `Form` draws flat
    /// and borderless to match System Settings, so a populated one is
    /// indistinguishable from static label text: nothing says you may type.
    /// `.roundedBorder` is the native affordance for that and is the whole
    /// fix for it.
    ///
    /// The second is that the field's name was only its *placeholder*, which
    /// disappears the moment there is content. In the Styles rows the fields
    /// sit inside `HStack`/`VStack`, so `Form`'s automatic label column never
    /// applies either — leaving three populated boxes with no border and no
    /// label, unidentifiable and apparently inert. The caption is a real
    /// label that stays. Wrapping also makes Quick Improve behave the same
    /// way rather than getting `Form`'s side label, which is what keeps one
    /// component from rendering two different ways on one screen.
    ///
    /// The prompt stays on the `TextField` for VoiceOver and for the empty
    /// state; the caption is hidden from accessibility so it is not read
    /// twice.
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(prompt)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            field
        }
    }

    private var field: some View {
        TextField(prompt, text: $draft, axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .lineLimit(lineLimit)
            .onAppear { draft = value }
            .onChange(of: draft) { _, edited in
                guard let cleaned = validate(edited) else { return }
                value = cleaned
            }
            // Re-sync when something *other* than this field moved the value —
            // "Reset to default" is the one that does, and without this the
            // field would keep showing what the user had replaced. Guarded so
            // it cannot fight its own edits: while the user is typing, the
            // stored value is by definition the cleaned draft.
            .onChange(of: value) { _, stored in
                if validate(draft) != stored { draft = stored }
            }
    }
}

// MARK: - Privacy

private struct PrivacyTab: View {
    @ObservedObject var settings: AppSettings
    let automaticUpdateChecks: Binding<Bool>
    @State private var newEntry = ""
    @State private var rejected = false

    var body: some View {
        Form {
            Section("Where your text goes") {
                // Pinned by a test in `AppCore`. This said "Nowhere.", which
                // was false: the clipboard is how a selection is read in a
                // terminal or a PDF, and the general pasteboard syncs over
                // Handoff. There is no API to opt out, so the claim is what
                // got corrected.
                Text(PrivacyCopy.whereTextGoes)
                Text("Password and secure fields are refused before they are read.")
                    .foregroundStyle(.secondary)
                Text("Nothing you select or generate is written to the system log or to Everest's own diagnostics file in ~/Library/Logs/Everest.")
                    .foregroundStyle(.secondary)
            }

            // Here and not in General, because this screen is where the
            // claim about what leaves the machine is made. An update check
            // is the only outbound request Everest makes once the model is
            // on disk, so the switch for it belongs beside that claim rather
            // than three tabs away.
            Section("Software updates") {
                Toggle("Check for updates automatically", isOn: automaticUpdateChecks)
                Text(
                    """
                    Asks GitHub whether a newer version exists, on a schedule. That request \
                    carries your IP address, the app version and your macOS version, and nothing \
                    about your text. Turning this off leaves Check for Updates in the menu-bar \
                    menu working.
                    """
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Section("Never read from these apps") {
                // Not optional, and the wording is pinned by a test in
                // `AppCore`. It used to sit on the onboarding capability
                // screen, one step and several days away from the list it
                // describes; here it is read by the person actually typing
                // a bundle id in. A user who takes this list for the
                // protection adds their bank to it, gets nothing back —
                // matching is exact, and banking on a Mac is a browser tab
                // no entry will ever cover — and never finds out.
                Text(OnboardingModel.exclusionCaveat)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                // An explicit button, not `.onDelete`. That is a `List`
                // gesture and does nothing inside a macOS `Form` — the same
                // trap already recorded for the Styles list, which this row
                // had too. It mattered more here: the excluded-app refusal
                // message tells the user to come and remove the entry.
                ForEach(settings.excludedBundleIDs, id: \.self) { entry in
                    HStack {
                        Text(entry).monospaced()
                        Spacer()
                        Button(role: .destructive) {
                            settings.excludedBundleIDs = ExclusionEdit.remove(entry, from: settings.excludedBundleIDs)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .accessibilityLabel("Stop excluding \(entry)")
                    }
                }

                HStack {
                    // Same borderless-in-a-Form problem, but only that half:
                    // this field is empty in its steady state — Add clears
                    // it — so its placeholder never disappears and it needs
                    // no separate label.
                    TextField("Bundle identifier, e.g. com.example.bank", text: $newEntry)
                        .textFieldStyle(.roundedBorder)
                    Button("Add") { add() }
                }
                if rejected {
                    Text("That is blank or already on the list.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Text(
                    """
                    Matched exactly, so each entry is one app. A bank you use in a browser is \
                    covered by the secure-field refusal instead, not by this list.
                    """
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Section("Licences") {
                Text("mlx-swift-lm, swift-transformers, swift-huggingface — MIT and Apache 2.0.")
                Text("Qwen3 model weights — Apache 2.0.")
                Text("KeyboardShortcuts — MIT.")
            }
        }
        .formStyle(.grouped)
    }

    private func add() {
        guard let updated = ExclusionEdit.add(newEntry, to: settings.excludedBundleIDs) else {
            rejected = true
            return
        }
        settings.excludedBundleIDs = updated
        newEntry = ""
        rejected = false
    }
}
