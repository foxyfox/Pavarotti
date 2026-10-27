import Dictation
import SwiftUI

/// The bubble itself: a dark rounded shape at the bottom of its panel. Reads the phase
/// straight from the controller and the waveform from the meter.
struct DictationBubbleView: View {
    let controller: DictationController
    let meter: DictationLevelMeter

    private var isVisible: Bool {
        controller.phase != .idle || controller.notice != nil
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if isVisible {
                content
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(minHeight: 44)
                    .background(Self.shape.fill(Color.black.opacity(0.84)))
                    .overlay(Self.shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                    .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .bottom)))
            }
        }
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 12)
        .animation(.easeOut(duration: 0.18), value: isVisible)
        .animation(.easeOut(duration: 0.18), value: controller.phase)
    }

    private static var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
    }

    @ViewBuilder
    private var content: some View {
        switch controller.phase {
        case .listening:
            HStack(spacing: 10) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse)
                Text(meter.elapsedText)
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
                WaveformBars(levels: meter.levels)
                    .frame(width: 160, height: 24)
            }
        case .transcribing:
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Transcribing\u{2026}")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                WaveformBars(levels: meter.levels)
                    .frame(width: 80, height: 24)
                    .opacity(0.35)
            }
        case let .failed(text):
            message(text, systemImage: "exclamationmark.triangle.fill", tint: .orange)
        case .idle:
            message(controller.notice ?? "", systemImage: "character.book.closed.fill", tint: .white.opacity(0.7))
        }
    }

    private func message(_ text: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 420)
    }
}

/// The waveform: one rounded bar per level, oldest on the left, mirrored around the middle
/// and fading towards the past.
struct WaveformBars: View {
    let levels: [Float]

    /// The height of a silent bar, so the line stays visible.
    private static let minimumHeight: CGFloat = 3

    var body: some View {
        Canvas { context, size in
            guard !levels.isEmpty else { return }
            let slot = size.width / CGFloat(levels.count)
            let barWidth = max(1.5, slot * 0.6)
            for (index, level) in levels.enumerated() {
                let height = Self.minimumHeight + (size.height - Self.minimumHeight) * CGFloat(level)
                let rect = CGRect(
                    x: CGFloat(index) * slot + (slot - barWidth) / 2,
                    y: (size.height - height) / 2,
                    width: barWidth,
                    height: height
                )
                let age = CGFloat(index + 1) / CGFloat(levels.count)
                context.fill(
                    Path(roundedRect: rect, cornerRadius: barWidth / 2),
                    with: .color(.white.opacity(0.3 + 0.7 * age))
                )
            }
        }
        .accessibilityHidden(true)
    }
}
