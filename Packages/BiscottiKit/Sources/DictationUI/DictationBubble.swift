import Dictation
import SwiftUI

/// What the recording bubble shows.
enum BubbleContent {
    case listening(elapsed: String, levels: [Float])
    /// The waveform keeps the last levels, dimmed, and the time stops.
    case transcribing(elapsed: String, levels: [Float])
    case message(String, systemImage: String, tint: Color)
}

/// The recording bubble in the chosen size and style. The indicator panel and the preview
/// in Settings both draw it.
struct DictationBubble: View {
    let content: BubbleContent
    let appearance: BubbleAppearance

    private var metrics: BubbleMetrics {
        BubbleMetrics.of(appearance.size)
    }

    var body: some View {
        contentView
            .padding(.horizontal, metrics.horizontalPadding)
            .padding(.vertical, metrics.verticalPadding)
            .frame(minHeight: metrics.height)
            .modifier(BubbleBackground(style: appearance.style, cornerRadius: metrics.height / 2))
    }

    @ViewBuilder
    private var contentView: some View {
        switch content {
        case let .listening(elapsed, levels):
            HStack(spacing: metrics.spacing) {
                Image(systemName: "circle.fill")
                    .font(.system(size: metrics.dotSize))
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse)
                if metrics.showsTime {
                    time(elapsed)
                }
                waveform(levels, width: metrics.waveform.width)
            }
        case let .transcribing(elapsed, levels):
            transcribing(elapsed: elapsed, levels: levels)
        case let .message(text, systemImage, tint):
            HStack(spacing: metrics.spacing) {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                Text(text)
                    .foregroundStyle(Color.primary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: metrics.fontSize, weight: .medium))
            .frame(maxWidth: metrics.messageWidth)
        }
    }

    /// The large bubble says "Transcribing"; the small ones keep their width and swap the
    /// red dot for a spinner.
    private func transcribing(elapsed: String, levels: [Float]) -> some View {
        HStack(spacing: metrics.spacing) {
            ProgressView()
                .controlSize(appearance.size == .large ? .small : .mini)
            if appearance.size == .large {
                Text("Transcribing\u{2026}")
                    .font(.system(size: metrics.fontSize, weight: .medium))
                    .foregroundStyle(Color.primary)
                waveform(levels, width: metrics.waveform.width / 2)
                    .opacity(0.35)
            } else {
                if metrics.showsTime {
                    time(elapsed)
                }
                waveform(levels, width: metrics.waveform.width)
                    .opacity(0.35)
            }
        }
    }

    private func time(_ elapsed: String) -> some View {
        Text(elapsed)
            .font(.system(size: metrics.fontSize, weight: .medium).monospacedDigit())
            .foregroundStyle(Color.primary.opacity(0.85))
    }

    private func waveform(_ levels: [Float], width: CGFloat) -> some View {
        WaveformBars(levels: Array(levels.suffix(metrics.barCount)))
            .frame(width: width, height: metrics.waveform.height)
    }
}

/// The measurements of one bubble size.
struct BubbleMetrics {
    let height: CGFloat
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    let spacing: CGFloat
    let fontSize: CGFloat
    let dotSize: CGFloat
    let waveform: CGSize
    /// How many of the latest levels the waveform shows, so small bars stay apart.
    let barCount: Int
    let messageWidth: CGFloat
    let showsTime: Bool

    static func of(_ size: BubbleAppearance.Size) -> BubbleMetrics {
        switch size {
        case .minimal:
            BubbleMetrics(
                height: 24, horizontalPadding: 9, verticalPadding: 4, spacing: 6, fontSize: 11, dotSize: 5,
                waveform: CGSize(width: 40, height: 12), barCount: 14, messageWidth: 280, showsTime: false
            )
        case .compact:
            BubbleMetrics(
                height: 30, horizontalPadding: 11, verticalPadding: 5, spacing: 7, fontSize: 11, dotSize: 6,
                waveform: CGSize(width: 64, height: 16), barCount: 22, messageWidth: 320, showsTime: true
            )
        case .large:
            BubbleMetrics(
                height: 44, horizontalPadding: 16, verticalPadding: 10, spacing: 10, fontSize: 13, dotSize: 8,
                waveform: CGSize(width: 160, height: 24), barCount: DictationLevelMeter.barCount,
                messageWidth: 420, showsTime: true
            )
        }
    }
}

/// The bubble's material: Liquid Glass (a thin material before macOS 26), frosted, or dark.
/// Text in the bubble uses the primary color, so it follows light and dark mode; the dark
/// style always draws in dark mode.
private struct BubbleBackground: ViewModifier {
    let style: BubbleAppearance.Style
    let cornerRadius: CGFloat

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    func body(content: Content) -> some View {
        switch style {
        case .glass:
            if #available(macOS 26.0, *) {
                content.glassEffect(.regular, in: shape)
            } else {
                content
                    .background(.ultraThinMaterial, in: shape)
                    .overlay(shape.strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5))
            }
        case .frosted:
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
        case .dark:
            content
                .background(shape.fill(Color.black.opacity(0.84)))
                .overlay(shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                .environment(\.colorScheme, .dark)
        }
    }
}

/// The waveform: one rounded bar per level, oldest on the left, mirrored around the middle
/// and fading towards the past.
struct WaveformBars: View {
    let levels: [Float]

    /// The height of a silent bar, so the line stays visible.
    private static let minimumHeight: CGFloat = 2

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
                    with: .color(Color.primary.opacity(0.3 + 0.7 * age))
                )
            }
        }
        .accessibilityHidden(true)
    }
}
