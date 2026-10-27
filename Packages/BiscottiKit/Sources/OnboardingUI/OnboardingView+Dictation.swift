import AppKit
import CohereTranscribe
import DesignSystem
import SwiftUI

// Pavarotti: the Accessibility row and the Cohere Transcribe row of the setup.

extension OnboardingView {
    /// Accessibility lets Pavarotti paste dictated text. Granting it happens in System
    /// Settings, so the row looks again whenever the app comes back to the front.
    var accessibilityRow: some View {
        PermissionRow(
            icon: "keyboard",
            name: "Accessibility",
            why: "Paste dictated text where you type."
        ) {
            if viewModel.accessibilityGranted {
                GrantedTag()
            } else {
                GrantPill {
                    viewModel.requestAccessibility()
                }
            }
        }
        .onAppear {
            viewModel.dictation?.refreshAccessibility()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            viewModel.dictation?.refreshAccessibility()
        }
    }
}

extension ModelCard {
    /// Cohere Transcribe for dictation, with the model choice before installing.
    @ViewBuilder
    var dictationRow: some View {
        if viewModel.dictation != nil {
            let state = viewModel.dictationRowState()
            ModelDownloadRow(
                icon: "mic",
                name: "Dictation \u{00B7} Cohere Transcribe",
                why: "Push-to-talk dictation in German and English.",
                state: state,
                onDownload: { viewModel.startDictationDownload() },
                extraContent: {
                    switch state {
                    case .idle, .failed, .insufficientDisk:
                        DictationModelMenu(
                            selected: viewModel.dictationModel,
                            onChoose: { viewModel.chooseDictationModel($0) }
                        )
                    case .downloading, .ready, .checking:
                        EmptyView()
                    }
                }
            )

            InsetDivider(leadingInset: 48)
        }
    }
}

/// The selected Cohere model with a menu of all of them and their download sizes.
struct DictationModelMenu: View {
    let selected: CohereModel?
    let onChoose: (CohereModel) -> Void

    var body: some View {
        Menu {
            ForEach(CohereModel.all) { model in
                Button {
                    onChoose(model)
                } label: {
                    if model == selected {
                        Label(Self.title(of: model), systemImage: "checkmark")
                    } else {
                        Text(Self.title(of: model))
                    }
                }
            }
        } label: {
            Text(selected?.displayName ?? "Choose a model")
                .font(.system(size: 12.5))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(.inkSecondary)
        .padding(.top, 6)
    }

    static func title(of model: CohereModel) -> String {
        "\(model.displayName), \(ByteCountFormatter.string(fromByteCount: model.asset.size, countStyle: .file))"
    }
}
