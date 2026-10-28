import DesignSystem
import Dictation
import SwiftUI

/// The dictionary part of the dictation settings: learning on or off and the editor.
struct DictionarySection: View {
    let controller: DictationController
    @State private var isEditing = false

    var body: some View {
        Section("Dictionary") {
            VStack(alignment: .leading, spacing: Tokens.spacingXS) {
                Toggle("Learn from my corrections", isOn: learnsBinding)
                Text("When you fix a word right after dictating and press Return or Tab, the fix goes into the dictionary and is used from then on.")
                    .font(Tokens.metadataFont)
                    .foregroundStyle(Tokens.secondaryText)
            }
            HStack {
                VStack(alignment: .leading, spacing: Tokens.spacingXS) {
                    Text("Corrections")
                    Text(summary)
                        .font(Tokens.metadataFont)
                        .foregroundStyle(Tokens.secondaryText)
                }
                Spacer()
                Button("Edit\u{2026}") { isEditing = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .sheet(isPresented: $isEditing) {
            DictionaryEditor(dictionary: controller.dictionary)
        }
    }

    private var summary: String {
        let entries = controller.dictionary.entries
        let learned = entries.count(where: { $0.source == .learned })
        switch entries.count {
        case 0: return String(localized: "None yet.")
        case 1: return learned == 1 ? String(localized: "1 correction, learned.") : String(localized: "1 correction.")
        default:
            return learned > 0
                ? String(localized: "\(entries.count) corrections, \(learned) learned.")
                : String(localized: "\(entries.count) corrections.")
        }
    }

    private var learnsBinding: Binding<Bool> {
        Binding(
            get: { controller.settings.learnsFromCorrections },
            set: { newValue in controller.update { $0.learnsFromCorrections = newValue } }
        )
    }
}

/// Lists, adds and removes dictionary corrections.
struct DictionaryEditor: View {
    let dictionary: PersonalDictionary
    @Environment(\.dismiss) private var dismiss
    @State private var heard = ""
    @State private var written = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spacingMD) {
            Text("Dictionary")
                .font(.title3.weight(.semibold))
            addRow
            if let error {
                Text(error)
                    .font(Tokens.metadataFont)
                    .foregroundStyle(Color.warningChipText)
            }
            List {
                ForEach(sortedEntries) { entry in
                    DictionaryEntryRow(entry: entry, dictionary: dictionary)
                }
            }
            .frame(minHeight: 260)
            .overlay {
                if dictionary.entries.isEmpty {
                    Text("No corrections yet.")
                        .foregroundStyle(Tokens.secondaryText)
                }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Tokens.spacingLG)
        .frame(width: 560, height: 480)
    }

    private var addRow: some View {
        HStack {
            TextField("Heard", text: $heard)
            Image(systemName: "arrow.right")
                .foregroundStyle(Tokens.secondaryText)
            TextField("Written", text: $written)
                .onSubmit(add)
            Button("Add", action: add)
                .disabled(heard.isEmpty || written.isEmpty)
        }
        .textFieldStyle(.roundedBorder)
    }

    /// Newest first, so a just learned or added correction is on top.
    private var sortedEntries: [DictionaryEntry] {
        dictionary.entries.sorted { $0.createdAt > $1.createdAt }
    }

    private func add() {
        do {
            try dictionary.add(original: heard, replacement: written)
            heard = ""
            written = ""
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// One correction: on/off, heard → written, where it came from and how often it helped.
struct DictionaryEntryRow: View {
    let entry: DictionaryEntry
    let dictionary: PersonalDictionary

    var body: some View {
        HStack {
            Toggle("", isOn: enabledBinding)
                .labelsHidden()
            Text(entry.original)
                .strikethrough(!entry.isEnabled)
            Image(systemName: "arrow.right")
                .foregroundStyle(Tokens.secondaryText)
            Text(entry.replacement)
                .fontWeight(.medium)
            Spacer()
            Text(detail)
                .font(Tokens.metadataFont)
                .foregroundStyle(Tokens.secondaryText)
            Button {
                dictionary.remove(id: entry.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove")
        }
    }

    private var detail: String {
        let origin = switch entry.source {
        case .manual: String(localized: "added")
        case .learned: String(localized: "learned")
        case .imported: "TypeWhisper"
        }
        return entry.usageCount > 0 ? String(localized: "\(origin), used \(entry.usageCount)\u{00D7}") : origin
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { entry.isEnabled },
            set: { newValue in dictionary.setEnabled(newValue, id: entry.id) }
        )
    }
}
