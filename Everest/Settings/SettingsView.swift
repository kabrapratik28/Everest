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

    var body: some View {
        TabView {
            GeneralTab(presence: presence, isAccessibilityTrusted: isAccessibilityTrusted)
                .tabItem { Label("General", systemImage: "gearshape") }
            ModelTab(models: models)
                .tabItem { Label("Model", systemImage: "cpu") }
            PromptsTab(settings: settings)
                .tabItem { Label("Prompts", systemImage: "text.quote") }
            PrivacyTab(settings: settings)
                .tabItem { Label("Privacy", systemImage: "lock") }
        }
        .frame(width: 560, height: 460)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @ObservedObject var presence: AppPresence
    let isAccessibilityTrusted: () -> Bool

    @State private var isTrusted = false
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
                Text("⌘I is Italic in most apps. Everest takes it globally while it is set.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
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
        .onAppear { isTrusted = isAccessibilityTrusted() }
        .onReceive(poll) { _ in isTrusted = isAccessibilityTrusted() }
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
                        Text(row.spec.displayName).font(.headline)
                        // The blurb inline, which is the only place a user
                        // learns that Apple's engine has a content filter they
                        // cannot switch off before it cuts a rewrite in half.
                        Text(row.spec.blurb).font(.callout).foregroundStyle(.secondary)
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }

                    // The blurb and the empty space beside it are part of the
                    // target: a radio button whose label is not clickable is
                    // the complaint this replaced.
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(row.spec.displayName). \(row.spec.blurb). \(status)")
            .accessibilityAddTraits(row.isSelected ? [.isSelected] : [])
            .accessibilityHint("Rewrites with this model")

            if let progress = models.downloadProgress[row.spec.id] {
                ProgressView(value: progress).frame(width: 120)
            } else {
                VStack(alignment: .trailing) {
                    if case .needsDownload = row.availability, !row.spec.repoID.isEmpty {
                        Button("Download") { Task { try? await models.download(row.spec) } }
                    }
                    Button("Delete", role: .destructive) {
                        Task { try? await models.delete(row.spec) }
                    }
                    .disabled(!models.canDelete(row.spec))
                }
            }
        }
    }

    private var status: String {
        switch row.availability {
        case .ready:
            "Installed"
        case let .needsDownload(bytes):
            row.spec.repoID.isEmpty
                ? "No download needed"
                : "\(Measurement(value: Double(bytes), unit: UnitInformationStorage.bytes).formatted(.byteCount(style: .file))) to download"
        case let .unavailable(reason):
            reason
        }
    }
}

// MARK: - Prompts

private struct PromptsTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            // Name, subtitle and instruction — every field of the preset the
            // user owns. `PromptBuilder.safetyFrame` is the one that is not
            // theirs, and it is not reachable from this screen and must never
            // become so: it is the prompt-injection frame, and a user-editable
            // frame is not a frame. See RewriteCore/AGENTS.md.
            Section("Quick Improve") {
                PresetField("Name", text: $settings.quickImprove.name, validate: PresetEdit.name(from:))
                PresetField(
                    "Subtitle",
                    text: $settings.quickImprove.subtitle,
                    validate: { PresetEdit.subtitle(from: $0) as String? }
                )
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
                            Button(role: .destructive) {
                                settings.styles.remove(at: index)
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

    private func move(_ index: Int, by offset: Int) {
        let destination = index + offset
        guard settings.styles.indices.contains(destination) else { return }
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

    var body: some View {
        TextField(prompt, text: $draft, axis: .vertical)
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
    @State private var newEntry = ""
    @State private var rejected = false

    var body: some View {
        Form {
            Section("Where your text goes") {
                Text(
                    """
                    Nowhere. Everest runs the model on this Mac. No selection, no rewrite and \
                    no telemetry is sent anywhere, and nothing you select or generate is \
                    written to the system log.
                    """
                )
                Text("Password and secure fields are refused before they are read.")
                    .foregroundStyle(.secondary)
            }

            Section("Never read from these apps") {
                ForEach(settings.excludedBundleIDs, id: \.self) { Text($0).monospaced() }
                    .onDelete { settings.excludedBundleIDs.remove(atOffsets: $0) }

                HStack {
                    TextField("Bundle identifier, e.g. com.example.bank", text: $newEntry)
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
