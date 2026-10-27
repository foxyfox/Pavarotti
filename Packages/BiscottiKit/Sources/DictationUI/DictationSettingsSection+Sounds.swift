import AppKit
import DesignSystem
import Dictation
import SwiftUI
import UniformTypeIdentifiers

extension DictationSettingsSection {
    @ViewBuilder
    var soundRows: some View {
        Toggle("Play sounds", isOn: playsSoundsBinding)
        if controller.settings.playsSounds {
            SoundPickerRow(title: "Start", caption: "When the microphone is listening.", controller: controller, slot: .start)
            SoundPickerRow(title: "Done", caption: "When the text was pasted.", controller: controller, slot: .done)
            SoundPickerRow(title: "Error", caption: "When something went wrong.", controller: controller, slot: .error)
        }
    }

    @ViewBuilder
    var duckingRows: some View {
        VStack(alignment: .leading, spacing: Tokens.spacingXS) {
            Toggle("Lower other audio while listening", isOn: ducksAudioBinding)
            Text("Music and calls get quieter while you dictate and come back afterwards.")
                .font(Tokens.metadataFont)
                .foregroundStyle(Tokens.secondaryText)
        }
        if controller.settings.ducksAudio {
            HStack {
                Text("Other audio at")
                Slider(value: duckingLevelBinding, in: 0 ... 0.8, step: 0.05)
                Text("\(Int((controller.settings.duckingLevel * 100).rounded())) %")
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }

    var playsSoundsBinding: Binding<Bool> {
        Binding(
            get: { controller.settings.playsSounds },
            set: { newValue in controller.update { $0.playsSounds = newValue } }
        )
    }

    var ducksAudioBinding: Binding<Bool> {
        Binding(
            get: { controller.settings.ducksAudio },
            set: { newValue in controller.update { $0.ducksAudio = newValue } }
        )
    }

    var duckingLevelBinding: Binding<Double> {
        Binding(
            get: { controller.settings.duckingLevel },
            set: { newValue in controller.update { $0.duckingLevel = newValue } }
        )
    }
}

/// Which cue a sound picker edits.
enum SoundSlotChoice {
    case start
    case done
    case error
}

/// Picks the sound for one cue: none, a system sound or one of the user's files.
struct SoundPickerRow: View {
    let title: String
    let caption: String
    let controller: DictationController
    let slot: SoundSlotChoice
    @State private var importError: String?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: Tokens.spacingXS) {
                Picker(title, selection: selection) {
                    Text("None").tag(SoundChoice.none)
                    Section("System") {
                        ForEach(SoundLibrary.systemSoundNames, id: \.self) { name in
                            Text(name).tag(SoundChoice.system(name))
                        }
                    }
                    if !controller.customSounds.isEmpty {
                        Section("Your Sounds") {
                            ForEach(controller.customSounds, id: \.self) { name in
                                Text(SoundChoice.file(name).displayName).tag(SoundChoice.file(name))
                            }
                        }
                    }
                }
                Text(importError ?? caption)
                    .font(Tokens.metadataFont)
                    .foregroundStyle(importError == nil ? Tokens.secondaryText : Color.warningOchre)
            }
            Button {
                controller.preview(current)
            } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.borderless)
            .help("Play")
            .disabled(current == .none)
            Button("Add File\u{2026}") { addFile() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    private var current: SoundChoice {
        switch slot {
        case .start: controller.settings.startSound
        case .done: controller.settings.doneSound
        case .error: controller.settings.errorSound
        }
    }

    private var selection: Binding<SoundChoice> {
        Binding(
            get: { current },
            set: { newValue in apply(newValue) }
        )
    }

    private func apply(_ choice: SoundChoice) {
        controller.update { settings in
            switch slot {
            case .start: settings.startSound = choice
            case .done: settings.doneSound = choice
            case .error: settings.errorSound = choice
            }
        }
    }

    private func addFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a sound for \u{201C}\(title)\u{201D}"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let choice = try controller.importSound(from: url)
            apply(choice)
            importError = nil
        } catch {
            importError = error.localizedDescription
        }
    }
}
