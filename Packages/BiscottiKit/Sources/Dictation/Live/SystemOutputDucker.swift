import AudioToolbox
import CoreAudio
import Foundation

/// Lowers the volume of the default output device while dictating and restores it.
@MainActor
public final class SystemOutputDucker: OutputDucking {
    private struct Saved {
        let device: AudioObjectID
        let volume: Float32
    }

    private var saved: Saved?

    public init() {}

    public func duck(to level: Double) {
        guard saved == nil,
              let device = Self.defaultOutputDevice(),
              let volume = Self.volume(of: device)
        else { return }
        let target = Float32(max(0, min(1, Double(volume) * level)))
        guard Self.setVolume(target, of: device) else { return }
        saved = Saved(device: device, volume: volume)
    }

    public func restore() {
        guard let snapshot = saved else { return }
        saved = nil
        // Back on the device that was ducked, even if the default output changed since.
        _ = Self.setVolume(snapshot.volume, of: snapshot.device)
    }

    // MARK: - Core Audio

    private static func defaultOutputDevice() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        )
        guard status == noErr, device != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return device
    }

    private static func volumeAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func volume(of device: AudioObjectID) -> Float32? {
        var address = volumeAddress()
        var volume = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume)
        return status == noErr ? volume : nil
    }

    private static func setVolume(_ volume: Float32, of device: AudioObjectID) -> Bool {
        var address = volumeAddress()
        var value = volume
        let size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectSetPropertyData(device, &address, 0, nil, size, &value) == noErr
    }
}
