import AppCore
import DesignSystem
import Intelligence
import SwiftUI

/// Pavarotti: the voices taken over from TypeWhisper, which name speakers in meetings.
struct VoicesSettingsSection: View {
    static let title = "Voices"

    let appCore: AppCore
    @State private var voices: [ImportedVoice] = []
    @State private var message: String?
    @State private var isImporting = false

    var body: some View {
        Section(Self.title) {
            VStack(alignment: .leading, spacing: Tokens.spacingXS) {
                HStack {
                    Text(listing)
                        .lineLimit(2)
                    Spacer()
                    Button("Import from TypeWhisper") { importVoices() }
                        .disabled(isImporting)
                    Button("Remove") { removeVoices() }
                        .disabled(voices.isEmpty || isImporting)
                }
                Text(message ?? Self.explanation)
                    .font(Tokens.metadataFont)
                    .foregroundStyle(Tokens.secondaryText)
            }
        }
        .task { voices = appCore.importedVoices }
    }

    private static let explanation = "An imported voice names a speaker like one meeting in which you named them. "
        + "People come with the consent noted in TypeWhisper."

    private var listing: String {
        guard !voices.isEmpty else { return "No voices from TypeWhisper" }
        let names = voices.map { $0.personID == nil ? "you" : $0.name }
        return "From TypeWhisper: \(names.joined(separator: ", "))"
    }

    private func importVoices() {
        isImporting = true
        Task {
            message = await appCore.importTypeWhisperVoices(force: true)
            voices = appCore.importedVoices
            isImporting = false
        }
    }

    private func removeVoices() {
        do {
            try appCore.removeImportedVoices()
            message = "Removed the voices from TypeWhisper. Names and consents stay."
        } catch {
            message = "Removing failed: \(error.localizedDescription)"
        }
        voices = appCore.importedVoices
    }
}
