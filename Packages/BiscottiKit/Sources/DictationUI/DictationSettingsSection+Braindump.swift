import DesignSystem
import Dictation
import SwiftUI

// Pavarotti: pressing the shortcut twice to end a dictation structures it with the AI model.

extension DictationSettingsSection {
    var braindumpRow: some View {
        VStack(alignment: .leading, spacing: Tokens.spacingXS) {
            Toggle("Braindump on double press", isOn: braindumpBinding)
            Text("Press the shortcut twice quickly to end a dictation, and the AI model turns what you said into a structured note with headings and lists before it is pasted. Uses the model under AI Enhancements.")
                .font(Tokens.metadataFont)
                .foregroundStyle(Tokens.secondaryText)
        }
    }

    private var braindumpBinding: Binding<Bool> {
        Binding(
            get: { controller.settings.structuresOnDoublePress },
            set: { newValue in controller.update { $0.structuresOnDoublePress = newValue } }
        )
    }
}
