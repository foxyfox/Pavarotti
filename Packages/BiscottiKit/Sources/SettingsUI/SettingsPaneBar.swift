import AppCore
import DesignSystem
import SwiftUI

/// Pavarotti: the row of page buttons at the top of Settings, like the toolbar of a macOS
/// settings window, and a line on what the chosen page holds.
struct SettingsPaneBar: View {
    @Binding var selection: SettingsPane
    let panes: [SettingsPane]

    /// The chosen page, or the first one offered when it is not.
    private var shown: SettingsPane {
        panes.contains(selection) ? selection : panes.first ?? .general
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spacingSM) {
            HStack(spacing: Tokens.spacingXS) {
                ForEach(panes) { pane in
                    button(for: pane)
                }
            }
            Text(shown.caption)
                .font(Tokens.metadataFont)
                .foregroundStyle(Tokens.secondaryText)
        }
    }

    private func button(for pane: SettingsPane) -> some View {
        let isSelected = pane == shown
        return Button {
            selection = pane
        } label: {
            VStack(spacing: 3) {
                Image(systemName: pane.systemImage)
                    .font(.system(size: 17, weight: .medium))
                    .frame(height: 20)
                Text(pane.title)
                    .font(.system(size: 11, weight: .medium))
            }
            .frame(width: 84, height: 50)
            .foregroundStyle(isSelected ? Color.sage : Tokens.secondaryText)
            .background(
                isSelected ? Tokens.accentWashStrong : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(pane.caption)
    }
}
