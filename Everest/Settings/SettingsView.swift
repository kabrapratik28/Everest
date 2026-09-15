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
    let isAccessibilityTrusted: () -> Bool

    var body: some View {
        TabView {
            GeneralTab(settings: settings, isAccessibilityTrusted: isAccessibilityTrusted)
                .tabItem { Label("General", systemImage: "gearshape") }
            ModelTab(settings: settings, models: models)
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
    @ObservedObject var settings: AppSettings
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
    @ObservedObject var settings: AppSettings
    @ObservedObject var models: ModelSettingsModel

    @State private var sample = "we was hoping to maybe get your thoughts on the deck sometime this week if thats ok"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(models.rows) { row in
                ModelRow(row: row, settings: settings, models: models)
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

private struct ModelRow: View {
    let row: ModelSettingsModel.Row
    @ObservedObject var settings: AppSettings
    @ObservedObject var models: ModelSettingsModel

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.spec.displayName).font(.headline)
                // The blurb inline, which is the only place a user learns that
                // Apple's engine has a content filter they cannot switch off
                // before it cuts a rewrite in half.
                Text(row.spec.blurb).font(.callout).foregroundStyle(.secondary)
                Text(status).font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            Button(isSelected ? "In use" : "Use") { settings.engineID = row.spec.id }
                .disabled(isSelected)

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

    private var isSelected: Bool { settings.engineID == row.spec.id }

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
            // Only the instruction. `PromptBuilder.safetyFrame` is not
            // reachable from this screen and must never become so: it is the
            // prompt-injection frame, and a user-editable frame is not a
            // frame. See RewriteCore/AGENTS.md.
            Section("Quick Improve") {
                InstructionField(instruction: $settings.quickImprove.instruction)
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
                            TextField("Name", text: $style.name)
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
                        TextField("Subtitle", text: $style.subtitle)
                        InstructionField(instruction: $style.instruction)
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

/// Never lets an instruction be committed blank.
///
/// A blank instruction sends the model the safety frame, an empty line and the
/// user's text, leaving it to invent a task — and the invention lands in their
/// document. The rule is `PresetEdit.instruction(from:)`, in `AppCore`, which
/// is where it has a test.
///
/// The draft is kept separately from the stored value so trimming does not
/// fight the user's typing: a trailing space stays visible while they are
/// mid-word, and emptying the field leaves the last good instruction in place
/// rather than saving nothing.
private struct InstructionField: View {
    @Binding var instruction: String
    @State private var draft = ""

    var body: some View {
        TextField("Instruction", text: $draft, axis: .vertical)
            .lineLimit(2...6)
            .onAppear { draft = instruction }
            .onChange(of: draft) { _, edited in
                guard let cleaned = PresetEdit.instruction(from: edited) else { return }
                instruction = cleaned
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
