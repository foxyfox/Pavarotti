import AppCore
import AppKit
import DesignSystem
import MeetingNotes
import SwiftUI

/// Pavarotti: whether meetings get a Markdown note, where it goes, and which prompt
/// writes it.
struct MeetingNotesSettingsSection: View {
    static let title = "Meeting Notes"

    let appCore: AppCore
    private let store = MeetingNotesSettingsStore()
    @State private var settings = MeetingNotesSettingsStore().load()
    @State private var importMessage: String?
    @State private var isImporting = false

    var body: some View {
        Section(Self.title) {
            VStack(alignment: .leading, spacing: Tokens.spacingXS) {
                Toggle("Write a Markdown note for every meeting", isOn: enabledBinding)
                Text("After the AI run: the notes, the speakers and the whole transcript, in the format TypeWhisper wrote.")
                    .font(Tokens.metadataFont)
                    .foregroundStyle(Tokens.secondaryText)
            }
            LabeledContent("Folder") {
                HStack(spacing: Tokens.spacingSM) {
                    Text(settings.folder.path(percentEncoded: false))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(Tokens.secondaryText)
                        .help(settings.folder.path(percentEncoded: false))
                    Button("Choose\u{2026}") { chooseFolder() }
                    Button("Show") { NSWorkspace.shared.open(settings.folder) }
                }
            }
            VStack(alignment: .leading, spacing: Tokens.spacingXS) {
                HStack {
                    Text("Prompt: \(settings.templateName)")
                    Spacer()
                    Button("Take Over from TypeWhisper") { takeOverFromTypeWhisper() }
                        .disabled(isImporting)
                }
                Text(importMessage ?? "The summary prompt under AI Enhancements writes the notes. Taking over replaces it with TypeWhisper\u{2019}s.")
                    .font(Tokens.metadataFont)
                    .foregroundStyle(Tokens.secondaryText)
            }
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { settings.isEnabled },
            set: { isOn in
                settings.isEnabled = isOn
                store.save(settings)
            }
        )
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = settings.folder
        panel.prompt = "Choose"
        panel.message = "Choose the folder for meeting notes"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.folderPath = url.path(percentEncoded: false)
        store.save(settings)
    }

    private func takeOverFromTypeWhisper() {
        isImporting = true
        Task {
            importMessage = await appCore.importTypeWhisperNotesSetup(force: true)
            settings = store.load()
            isImporting = false
        }
    }
}
