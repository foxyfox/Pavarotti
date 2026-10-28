import DesignSystem
import Dictation
import SwiftUI

// Pavarotti: how long the speech model stays in memory without being used.

extension DictationSettingsSection {
    var retentionRows: some View {
        VStack(alignment: .leading, spacing: Tokens.spacingXS) {
            Picker("Keep the model loaded", selection: retentionBinding) {
                ForEach(ModelRetention.allCases) { retention in
                    Text(retention == .always ? "Always" : "For \(retention.displayName) without use")
                        .tag(retention)
                }
            }
            statusText(retentionCaption)
        }
    }

    private var retentionCaption: String {
        if controller.settings.modelRetention == .always {
            "Every dictation is fast, but the model keeps its memory."
        } else {
            "Frees the model\u{2019}s memory after a pause. The first dictation afterwards takes a few seconds longer."
        }
    }

    private var retentionBinding: Binding<ModelRetention> {
        Binding(
            get: { controller.settings.modelRetention },
            set: { newValue in controller.update { $0.modelRetention = newValue } }
        )
    }
}
