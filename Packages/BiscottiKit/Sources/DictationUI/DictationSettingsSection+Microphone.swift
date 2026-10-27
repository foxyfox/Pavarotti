import DesignSystem
import Dictation
import SwiftUI

// Pavarotti: which microphone dictation and meeting recordings use, and the permission to
// record it.

extension DictationSettingsSection {
    @ViewBuilder
    var microphoneRows: some View {
        VStack(alignment: .leading, spacing: Tokens.spacingXS) {
            Picker("Microphone", selection: microphoneBinding) {
                Text(defaultMicrophoneLabel).tag(String?.none)
                ForEach(controller.microphones) { device in
                    Text(device.name).tag(String?.some(device.id))
                }
                if let chosen = controller.settings.microphone, !controller.isChosenMicrophoneConnected {
                    Text("\(chosen.name) (not connected)").tag(String?.some(chosen.id))
                }
            }
            if !controller.isChosenMicrophoneConnected {
                statusText("Not connected. Pavarotti records from the system default until it is back.")
            } else {
                statusText("Dictations and meeting recordings use this microphone.")
            }
        }
        microphoneAccessRow
    }

    private var defaultMicrophoneLabel: String {
        controller.defaultMicrophone.map { "System default (\($0.name))" } ?? "System default"
    }

    @ViewBuilder
    private var microphoneAccessRow: some View {
        switch controller.microphonePermission {
        case .granted:
            EmptyView()
        case .undecided:
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.warningOchre)
                VStack(alignment: .leading, spacing: Tokens.spacingXS) {
                    Text("Microphone access")
                    statusText("Pavarotti asks the first time you dictate.")
                }
                Spacer()
                Button("Allow") { controller.requestMicrophonePermission() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        case .denied:
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.warningOchre)
                VStack(alignment: .leading, spacing: Tokens.spacingXS) {
                    Text("Microphone access")
                    statusText("Not allowed. Turn on Pavarotti in Privacy & Security \u{2192} Microphone.")
                }
                Spacer()
                Button("Open Settings") { SystemMicrophones.openSettings() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    var microphoneBinding: Binding<String?> {
        Binding(
            get: { controller.settings.microphone?.id },
            set: { id in
                guard let id else {
                    controller.chooseMicrophone(nil)
                    return
                }
                // The disconnected choice is not in the list; picking it keeps it.
                if let device = controller.microphones.first(where: { $0.id == id }) {
                    controller.chooseMicrophone(device)
                }
            }
        )
    }
}
