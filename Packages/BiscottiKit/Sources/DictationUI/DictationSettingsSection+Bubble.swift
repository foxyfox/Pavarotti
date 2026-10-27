import DesignSystem
import Dictation
import Foundation
import SwiftUI

extension DictationSettingsSection {
    static let bubbleTitle = "Recording Bubble"

    @ViewBuilder
    var bubbleRows: some View {
        Picker("Size", selection: bubbleSizeBinding) {
            ForEach(BubbleAppearance.Size.allCases) { size in
                Text(size.displayName).tag(size)
            }
        }
        .pickerStyle(.segmented)
        Picker("Look", selection: bubbleStyleBinding) {
            ForEach(BubbleAppearance.Style.allCases) { style in
                Text(style.displayName).tag(style)
            }
        }
        .pickerStyle(.segmented)
        Picker("Position", selection: bubblePositionBinding) {
            ForEach(BubbleAppearance.Position.allCases) { position in
                Text(position.displayName).tag(position)
            }
        }
        .pickerStyle(.segmented)
        BubblePreview(appearance: controller.settings.bubble)
    }

    var bubbleSizeBinding: Binding<BubbleAppearance.Size> {
        Binding(
            get: { controller.settings.bubble.size },
            set: { newValue in controller.update { $0.bubble.size = newValue } }
        )
    }

    var bubbleStyleBinding: Binding<BubbleAppearance.Style> {
        Binding(
            get: { controller.settings.bubble.style },
            set: { newValue in controller.update { $0.bubble.style = newValue } }
        )
    }

    var bubblePositionBinding: Binding<BubbleAppearance.Position> {
        Binding(
            get: { controller.settings.bubble.position },
            set: { newValue in controller.update { $0.bubble.position = newValue } }
        )
    }
}

/// The bubble as it looks while listening, over a colorful backdrop so the glass shows.
struct BubblePreview: View {
    let appearance: BubbleAppearance

    var body: some View {
        DictationBubble(content: .listening(elapsed: "0:07", levels: Self.sampleLevels), appearance: appearance)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Tokens.spacingLG)
            .background(Self.backdrop, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Preview of the recording bubble")
    }

    private static var backdrop: LinearGradient {
        LinearGradient(
            colors: [.blue.opacity(0.55), .purple.opacity(0.45), .orange.opacity(0.5)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// A made-up waveform, so the preview looks like someone is talking.
    private static var sampleLevels: [Float] {
        (0 ..< DictationLevelMeter.barCount).map { index in
            let wave = abs(sin(Double(index) * 0.55)) * abs(cos(Double(index) * 0.17))
            return Float(0.15 + 0.75 * wave)
        }
    }
}
