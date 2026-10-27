import DesignSystem
import SwiftUI

// Pavarotti: the setup can be run again, to download models or grant access later.

extension SettingsView {
    var setupRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: Tokens.spacingXS) {
                Text("Setup")
                Text("Permissions and model downloads, as on first launch. Your meetings and settings stay.")
                    .font(Tokens.metadataFont)
                    .foregroundStyle(Tokens.secondaryText)
            }
            Spacer()
            Button("Run Setup Again") {
                viewModel.replayOnboarding()
            }
            .controlSize(.small)
        }
    }
}
