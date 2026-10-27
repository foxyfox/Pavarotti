import DesignSystem
import DictationUI
import SwiftUI

/// Pavarotti: the sidebar rows for the recent dictations and the file transcription, styled
/// like Home and Past Meetings. Left out without dictation (tests and previews).
struct DictationSidebarRows: View {
    let viewModel: AppShellViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if viewModel.dictation != nil {
                SidebarRow(title: "Dictations", systemImage: "mic", isSelected: viewModel.route == .dictations) {
                    viewModel.showDictations()
                }
                SidebarRow(title: "Transcribe File", systemImage: "waveform", isSelected: viewModel.route == .transcribeFile) {
                    viewModel.showFileTranscription()
                }
            }
        }
    }
}

/// One sidebar row: an icon, tinted when selected, and a title on a highlighted background.
struct SidebarRow: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Tokens.spacingSM) {
                Image(systemName: systemImage)
                    .foregroundStyle(isSelected ? Color.sage : Tokens.secondaryText)
                Text(title)
                    .font(.body)
                Spacer()
            }
            .padding(.vertical, Tokens.spacingXS)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            isSelected ? Tokens.accentWashStrong : Color.clear,
            in: RoundedRectangle(cornerRadius: 4)
        )
    }
}

/// The Dictations or Transcribe File page, as the route says.
struct DictationPage: View {
    let viewModel: AppShellViewModel

    var body: some View {
        if let dictation = viewModel.dictation {
            if viewModel.route == .transcribeFile {
                FileTranscriptionPane(controller: dictation)
            } else {
                RecentDictationsView(controller: dictation)
            }
        } else {
            ContentUnavailableView("Dictation Is Not Available", systemImage: "mic.slash")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Tokens.contentBackground)
        }
    }
}
