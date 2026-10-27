import AppKit
import Dictation
import SwiftUI
import UniformTypeIdentifiers

/// The content of the file transcription window: a drop zone, the progress, then the
/// transcript with "Copy Markdown" and "Save as Markdown".
struct FileTranscriptionView: View {
    let session: FileTranscriptionSession
    @State private var isTargeted = false
    @State private var isChoosing = false
    /// What the last copy or save did.
    @State private var status: String?
    @State private var savedFile: URL?

    var body: some View {
        content
            .frame(minWidth: 420, idealWidth: 560, maxWidth: .infinity, minHeight: 320, idealHeight: 460, maxHeight: .infinity)
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first(where: \.isFileURL) else { return false }
                start(url)
                return true
            } isTargeted: { isTargeted = $0 }
            .fileImporter(isPresented: $isChoosing, allowedContentTypes: [.audiovisualContent]) { result in
                if case let .success(url) = result {
                    start(url)
                }
            }
            .onPasteCommand(of: [.fileURL]) { _ in
                if let url = FilePasteboard.fileURL() {
                    start(url)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch session.state {
        case .idle:
            dropZone(failure: nil)
        case let .failed(_, message):
            dropZone(failure: message)
        case let .transcribing(file, progress):
            progressView(file: file, progress: progress)
        case let .finished(transcript):
            resultView(transcript)
        }
    }

    private func start(_ url: URL) {
        status = nil
        savedFile = nil
        session.transcribe(url)
    }

    // MARK: - Drop zone

    private func dropZone(failure: String?) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Drop an audio or video file here")
                .font(.title3)
            Text("Or copy a file in Finder and paste it here with \u{2318}V.")
                .foregroundStyle(.secondary)
            Button("Choose File\u{2026}") {
                isChoosing = true
            }
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            } else if !session.isModelInstalled {
                Text("Install the Cohere model in Settings \u{2192} Dictation first.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.4))
        }
        .padding(20)
    }

    // MARK: - Progress

    private func progressView(file: URL, progress: Double) -> some View {
        VStack(spacing: 12) {
            Text(file.lastPathComponent)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            ProgressView(value: progress)
                .frame(maxWidth: 360)
            Text(progress > 0 ? "Transcribing\u{2026} \(Int(progress * 100)) %" : "Reading the file and loading the model\u{2026}")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button("Cancel") {
                session.cancel()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Result

    private func resultView(_ transcript: FileTranscript) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(transcript.title)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(Self.details(of: transcript))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Another File\u{2026}") {
                    isChoosing = true
                }
            }
            ScrollView {
                Text(transcript.transcriptText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                if let status {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let savedFile {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([savedFile])
                    }
                }
                Spacer()
                Button("Copy Markdown") {
                    copy(transcript)
                }
                Button("Save as Markdown\u{2026}") {
                    save(transcript)
                }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
    }

    /// "12:34 · German".
    private static func details(of transcript: FileTranscript) -> String {
        var parts = [FileTranscript.timestamp(transcript.duration)]
        if let code = transcript.language {
            parts.append(Locale.current.localizedString(forLanguageCode: code) ?? code)
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    private func copy(_ transcript: FileTranscript) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(transcript.markdown(), forType: .string)
        savedFile = nil
        status = "Copied to the clipboard."
    }

    private func save(_ transcript: FileTranscript) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = transcript.markdownFileName
        panel.directoryURL = transcript.source.deletingLastPathComponent()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(transcript.markdown().utf8).write(to: url, options: .atomic)
            savedFile = url
            status = "Saved as \u{201C}\(url.lastPathComponent)\u{201D}."
        } catch {
            savedFile = nil
            status = "Could not save: \(error.localizedDescription)"
        }
    }
}
