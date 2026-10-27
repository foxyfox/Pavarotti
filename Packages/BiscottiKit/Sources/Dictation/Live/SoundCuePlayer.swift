@preconcurrency import AVFoundation
import Foundation

/// Plays sound cues with `AVAudioPlayer`, keeping players prepared so a cue starts
/// without a delay.
@MainActor
public final class SoundCuePlayer: SoundCuePlaying {
    private let library: SoundLibrary
    private var players: [URL: AVAudioPlayer] = [:]

    public init(library: SoundLibrary) {
        self.library = library
    }

    @discardableResult
    public func play(_ choice: SoundChoice) -> TimeInterval? {
        guard let url = library.url(for: choice), let player = player(for: url) else { return nil }
        player.currentTime = 0
        guard player.play() else { return nil }
        return player.duration
    }

    private func player(for url: URL) -> AVAudioPlayer? {
        if let player = players[url] {
            return player
        }
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
        player.prepareToPlay()
        players[url] = player
        return player
    }
}
