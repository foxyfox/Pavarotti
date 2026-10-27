import AVFoundation
import CoreMedia
import Foundation

/// Reads every file AVFoundation plays (M4A, MP3, WAV, AIFF, CAF, FLAC, MOV, MP4) and
/// mixes all its audio tracks down to mono at the requested sample rate.
public struct AssetAudioReader: AudioFileReading {
    public init() {}

    public func duration(of url: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: url)
        _ = try await Self.audioTracks(of: asset, name: url.lastPathComponent)
        let seconds = try await asset.load(.duration).seconds
        return seconds.isFinite ? max(0, seconds) : 0
    }

    public func samples(of url: URL, sampleRate: Int) -> AsyncThrowingStream<[Float], any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await Self.decode(url, sampleRate: sampleRate) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func audioTracks(of asset: AVURLAsset, name: String) async throws -> [AVAssetTrack] {
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw FileTranscriptionError.unreadable(name)
        }
        guard !tracks.isEmpty else { throw FileTranscriptionError.noAudio(name) }
        return tracks
    }

    private static func decode(_ url: URL, sampleRate: Int, deliver: ([Float]) -> Void) async throws {
        let name = url.lastPathComponent
        let asset = AVURLAsset(url: url)
        let tracks = try await audioTracks(of: asset, name: name)
        guard let reader = try? AVAssetReader(asset: asset) else {
            throw FileTranscriptionError.unreadable(name)
        }
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: outputSettings(sampleRate: sampleRate))
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw FileTranscriptionError.unreadable(name) }
        reader.add(output)
        guard reader.startReading() else { throw FileTranscriptionError.unreadable(name) }
        while let buffer = output.copyNextSampleBuffer() {
            guard !Task.isCancelled else {
                reader.cancelReading()
                throw CancellationError()
            }
            let samples = floats(in: buffer)
            if !samples.isEmpty {
                deliver(samples)
            }
        }
        if reader.status == .failed {
            throw FileTranscriptionError.unreadable(name)
        }
    }

    /// Interleaved 32-bit float, which for one channel is plain mono samples.
    private static func outputSettings(sampleRate: Int) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Double(sampleRate),
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
    }

    private static func floats(in buffer: CMSampleBuffer) -> [Float] {
        guard let block = CMSampleBufferGetDataBuffer(buffer) else { return [] }
        let length = CMBlockBufferGetDataLength(block)
        var samples = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
        let status = samples.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: raw.count, destination: base)
        }
        return status == kCMBlockBufferNoErr ? samples : []
    }
}
