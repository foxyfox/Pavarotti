import Foundation
import Observation

/// The recent microphone levels and the running time of a dictation, for the recording
/// bubble's waveform. The bubble feeds it about 20 times a second while listening.
@MainActor @Observable
public final class DictationLevelMeter {
    /// How many levels the waveform shows, oldest first.
    public nonisolated static let barCount = 32
    /// How much of the previous level a falling level keeps, so the waveform eases off
    /// between words instead of flickering.
    static let release: Float = 0.5

    public private(set) var levels = DictationLevelMeter.silence
    /// Seconds since the dictation started.
    public private(set) var elapsed: TimeInterval = 0
    @ObservationIgnored private var startedAt: Date?

    public init() {}

    /// Starts a new dictation: a flat waveform and the timer at zero.
    public func start(at date: Date) {
        startedAt = date
        elapsed = 0
        levels = Self.silence
    }

    /// Adds the current level on the right. A rising level shows at once, a falling one
    /// eases off.
    public func record(_ level: Float, at date: Date) {
        let level = min(1, max(0, level))
        let previous = levels.last ?? 0
        let shown = level >= previous ? level : previous * Self.release + level * (1 - Self.release)
        levels.removeFirst()
        levels.append(shown)
        if let startedAt {
            elapsed = max(0, date.timeIntervalSince(startedAt))
        }
    }

    /// The running time as minutes and seconds, like "0:07".
    public var elapsedText: String {
        let seconds = Int(elapsed)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private nonisolated static var silence: [Float] {
        [Float](repeating: 0, count: barCount)
    }
}

public extension DictationController {
    /// The microphone's current loudness from 0 to 1, for the waveform.
    var inputLevel: Float {
        dependencies.audio.level
    }
}
