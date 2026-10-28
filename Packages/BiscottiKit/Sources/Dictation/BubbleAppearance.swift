import Foundation

/// How the recording bubble looks and where it sits on the screen.
public struct BubbleAppearance: Codable, Equatable, Sendable {
    /// How much the bubble shows.
    public enum Size: String, Codable, CaseIterable, Identifiable, Sendable {
        /// A small pill with only the waveform.
        case minimal
        /// A small pill with the running time and the waveform.
        case compact
        /// The roomy bubble with larger text and a wide waveform.
        case large

        public var id: Self {
            self
        }

        public var displayName: String {
            switch self {
            case .minimal: String(localized: "Minimal")
            case .compact: String(localized: "Compact")
            case .large: String(localized: "Large")
            }
        }
    }

    /// The bubble's material.
    public enum Style: String, Codable, CaseIterable, Identifiable, Sendable {
        /// Liquid Glass on macOS 26, a thin see-through material before.
        case glass
        /// A frosted, more opaque material that follows light and dark mode.
        case frosted
        /// The dark, nearly opaque bubble.
        case dark

        public var id: Self {
            self
        }

        public var displayName: String {
            switch self {
            case .glass: "Liquid Glass"
            case .frosted: String(localized: "Frosted")
            case .dark: String(localized: "Dark")
            }
        }
    }

    /// Where on the screen the bubble appears.
    public enum Position: String, Codable, CaseIterable, Identifiable, Sendable {
        case bottom
        case top

        public var id: Self {
            self
        }

        public var displayName: String {
            switch self {
            case .bottom: String(localized: "Bottom")
            case .top: String(localized: "Top")
            }
        }
    }

    public var size = Size.compact
    public var style = Style.glass
    public var position = Position.bottom

    public init(size: Size = .compact, style: Style = .glass, position: Position = .bottom) {
        self.size = size
        self.style = style
        self.position = position
    }

    /// Decodes field by field, like ``DictationSettings``.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = BubbleAppearance()
        size = container.value(.size, default: defaults.size)
        style = container.value(.style, default: defaults.style)
        position = container.value(.position, default: defaults.position)
    }
}
