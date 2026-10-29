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
/// Icons sit in a column of one width, so every title starts at the same place.
struct SidebarRow: View {
    /// The icon column's width.
    static let iconWidth: CGFloat = 18
    /// The gap between the icon column and the title.
    static let iconTitleSpacing = Tokens.spacingSM
    /// The room between the highlight's edge and the icon.
    static let inset: CGFloat = 6

    let title: LocalizedStringKey
    let systemImage: String
    let isSelected: Bool
    var showsUpdateDot = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Self.iconTitleSpacing) {
                Image(systemName: systemImage)
                    .foregroundStyle(isSelected ? Color.sage : Tokens.secondaryText)
                    .frame(width: Self.iconWidth)
                Text(title)
                    .font(.body)
                Spacer()
                if showsUpdateDot {
                    Circle()
                        .fill(Color.sage)
                        .frame(width: 8, height: 8)
                        .accessibilityLabel("Update available")
                }
            }
            .padding(.vertical, Tokens.spacingXS)
            .padding(.horizontal, Self.inset)
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
