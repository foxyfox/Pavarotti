import DesignSystem
import SwiftUI

/// Pavarotti: throws the running recording away, after asking, for a meeting that did
/// not take place, so it is not saved, transcribed or written as a note.
struct DiscardRecordingButton: View {
    let viewModel: RecordingViewModel
    @State private var isConfirming = false

    var body: some View {
        Button {
            isConfirming = true
        } label: {
            Label("Discard", systemImage: "trash")
                .font(.system(size: 13))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Color.inkSecondary)
        .help("Stop the recording without saving it")
        .confirmationDialog("Discard this recording?", isPresented: $isConfirming) {
            Button("Discard Recording", role: .destructive) {
                Task { await viewModel.discard() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The recording stops and is deleted with its notes. Nothing is transcribed.")
        }
    }
}
