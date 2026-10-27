import DesignSystem
import Dictation
import SwiftUI

/// Pavarotti: the Transcribe File page of the main window. It shares its transcription with
/// the menu bar's window, so a file started in one shows its progress and result in both.
public struct FileTranscriptionPane: View {
    let controller: DictationController

    public init(controller: DictationController) {
        self.controller = controller
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Tokens.spacingXS) {
                Text("Transcribe File")
                    .font(.serifHeadline)
                    .foregroundStyle(.ink)
                Text("Turns an audio or video file into a Markdown transcript, on this Mac with Cohere Transcribe.")
                    .font(Tokens.metadataFont)
                    .foregroundStyle(Tokens.secondaryText)
            }
            .padding(.horizontal, 20)
            .padding(.top, Tokens.spacingLG)
            FileTranscriptionView(session: SharedFileTranscription.session(for: controller))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Tokens.contentBackground.ignoresSafeArea())
    }
}

/// The app's one file transcription, shared by the window and the main window's page.
@MainActor
enum SharedFileTranscription {
    private static var current: FileTranscriptionSession?

    static func session(for controller: DictationController) -> FileTranscriptionSession {
        if let current {
            return current
        }
        let session = FileTranscriptionSession(controller: controller)
        current = session
        return session
    }
}
