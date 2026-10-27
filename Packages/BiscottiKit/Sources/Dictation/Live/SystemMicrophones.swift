import AppKit
import AVFoundation
import CoreAudio

/// The Mac's input devices through Core Audio, and the microphone permission through
/// `AVCaptureDevice`. Both are read fresh each time, so a device plugged in or a change in
/// System Settings counts at once.
@MainActor
public final class SystemMicrophones: MicrophoneProviding {
    public init() {}

    public var permission: MicrophonePermission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .undecided
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }

    public func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    public func devices() -> [MicrophoneDevice] {
        CoreAudioInputDevices.all().map(\.device)
    }

    public func defaultDevice() -> MicrophoneDevice? {
        CoreAudioInputDevices.defaultInput()?.device
    }

    /// Opens System Settings at Privacy & Security → Microphone.
    public static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

/// An input device with its Core Audio object, which is only valid while it is connected.
struct CoreAudioInputDevice {
    let objectID: AudioObjectID
    let device: MicrophoneDevice
}

/// Lists the devices that can record.
enum CoreAudioInputDevices {
    /// Every device with at least one input channel, in Core Audio's order.
    static func all() -> [CoreAudioInputDevice] {
        deviceIDs().compactMap(inputDevice)
    }

    static func defaultInput() -> CoreAudioInputDevice? {
        var address = globalAddress(kAudioHardwarePropertyDefaultInputDevice)
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objectID)
        guard status == noErr else { return nil }
        return inputDevice(objectID)
    }

    /// The connected device with the UID `uid`.
    static func device(withUID uid: String) -> CoreAudioInputDevice? {
        all().first { $0.device.id == uid }
    }

    private static func deviceIDs() -> [AudioObjectID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = globalAddress(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objectIDs = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objectIDs) == noErr else { return [] }
        return objectIDs
    }

    private static func inputDevice(_ objectID: AudioObjectID) -> CoreAudioInputDevice? {
        guard objectID != AudioObjectID(kAudioObjectUnknown),
              hasInputChannels(objectID),
              let uid = string(kAudioDevicePropertyDeviceUID, of: objectID)
        else {
            return nil
        }
        let name = string(kAudioObjectPropertyName, of: objectID) ?? uid
        return CoreAudioInputDevice(objectID: objectID, device: MicrophoneDevice(id: uid, name: name))
    }

    private static func hasInputChannels(_ objectID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, raw) == noErr else { return false }
        let buffers = UnsafeMutableAudioBufferListPointer(raw.bindMemory(to: AudioBufferList.self, capacity: 1))
        return buffers.contains { $0.mNumberChannels > 0 }
    }

    /// A string property, which Core Audio hands out as a retained `CFString`.
    private static func string(_ selector: AudioObjectPropertySelector, of objectID: AudioObjectID) -> String? {
        var address = globalAddress(selector)
        var size = UInt32(MemoryLayout<UnsafeRawPointer?>.size)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<UnsafeRawPointer?>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, raw) == noErr,
              let pointer = raw.load(as: UnsafeRawPointer?.self)
        else {
            return nil
        }
        return Unmanaged<CFString>.fromOpaque(pointer).takeRetainedValue() as String
    }

    private static func globalAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
