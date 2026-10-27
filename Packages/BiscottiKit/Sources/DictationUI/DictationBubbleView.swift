import Dictation
import SwiftUI

/// The bubble in its panel: at the top or bottom edge, as Settings choose. Reads the phase
/// straight from the controller and the waveform from the meter.
struct DictationBubbleView: View {
    let controller: DictationController
    let meter: DictationLevelMeter

    private var isVisible: Bool {
        controller.phase != .idle || controller.notice != nil
    }

    private var edge: VerticalEdge {
        controller.settings.bubble.position == .top ? .top : .bottom
    }

    var body: some View {
        ZStack {
            if isVisible {
                DictationBubble(content: content, appearance: controller.settings.bubble)
                    .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: edge == .top ? .top : .bottom)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: edge == .top ? .top : .bottom)
        .padding(edge == .top ? .top : .bottom, 12)
        .animation(.easeOut(duration: 0.18), value: isVisible)
        .animation(.easeOut(duration: 0.18), value: controller.phase)
    }

    private var content: BubbleContent {
        switch controller.phase {
        case .listening:
            .listening(elapsed: meter.elapsedText, levels: meter.levels)
        case .transcribing:
            .transcribing(elapsed: meter.elapsedText, levels: meter.levels)
        case let .failed(text):
            .message(text, systemImage: "exclamationmark.triangle.fill", tint: .orange)
        case .idle:
            .message(controller.notice ?? "", systemImage: "character.book.closed.fill", tint: .secondary)
        }
    }
}
