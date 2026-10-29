import AudioToolbox
import CoreAudio
import Foundation

/// Pavarotti: a Core Audio input unit (AUHAL) bound to one device, delivering mono float
/// samples at the device's rate from when it was opened.
///
/// Unlike `AVAudioEngine`, it never opens the system default input when another device
/// is chosen, so AirPods stay in their high-quality profile while the Studio Display
/// records, and it keeps its device when the default changes.
final class InputUnit: @unchecked Sendable {
    /// The most frames one callback renders; Core Audio asks for far fewer.
    static let maximumFrames = 16384

    /// The rate of the samples this unit delivers.
    let sampleRate: Double
    private let unit: AudioUnit
    /// Where the callback renders to. Only the audio thread writes it.
    private let buffer = UnsafeMutablePointer<Float>.allocate(capacity: InputUnit.maximumFrames)
    private let onSamples: @Sendable (UnsafeBufferPointer<Float>) -> Void

    private init(unit: AudioUnit, sampleRate: Double, onSamples: @escaping @Sendable (UnsafeBufferPointer<Float>) -> Void) {
        self.unit = unit
        self.sampleRate = sampleRate
        self.onSamples = onSamples
    }

    deinit {
        buffer.deallocate()
    }

    /// An input unit for `device`, configured but not running. `onSamples` runs on the
    /// audio thread.
    static func open(
        device: AudioObjectID,
        onSamples: @escaping @Sendable (UnsafeBufferPointer<Float>) -> Void
    ) throws -> InputUnit {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw DictationError.microphoneUnavailable("Core Audio has no input unit.")
        }
        var instance: AudioUnit?
        try check(AudioComponentInstanceNew(component, &instance), "Opening the input unit")
        guard let unit = instance else {
            throw DictationError.microphoneUnavailable("Core Audio has no input unit.")
        }
        do {
            try set(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, element: 1, to: UInt32(1))
            try set(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, element: 0, to: UInt32(0))
            try set(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, element: 0, to: device)
            let rate = try deviceSampleRate(of: unit)
            try set(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, element: 1, to: monoFloat(rate))
            return InputUnit(unit: unit, sampleRate: rate, onSamples: onSamples)
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }
    }

    /// Starts recording.
    func start() throws {
        let callback = AURenderCallbackStruct(
            inputProc: { refCon, flags, timeStamp, bus, frames, _ in
                Unmanaged<InputUnit>.fromOpaque(refCon).takeUnretainedValue()
                    .render(flags: flags, timeStamp: timeStamp, bus: bus, frames: frames)
            },
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        try Self.set(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, element: 0, to: callback)
        try Self.check(AudioUnitInitialize(unit), "Preparing the microphone")
        try Self.check(AudioOutputUnitStart(unit), "Starting the microphone")
    }

    /// Stops recording and releases the device. The unit cannot start again; once this
    /// returns, `onSamples` is not called any more.
    func close() {
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
    }

    // MARK: - Private

    private func render(
        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timeStamp: UnsafePointer<AudioTimeStamp>,
        bus: UInt32,
        frames: UInt32
    ) -> OSStatus {
        guard frames > 0, Int(frames) <= Self.maximumFrames else { return noErr }
        let byteSize = frames * UInt32(MemoryLayout<Float>.size)
        var list = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: byteSize, mData: UnsafeMutableRawPointer(buffer))
        )
        let status = AudioUnitRender(unit, flags, timeStamp, bus, frames, &list)
        guard status == noErr else { return status }
        let count = min(Int(frames), Int(list.mBuffers.mDataByteSize) / MemoryLayout<Float>.size)
        onSamples(UnsafeBufferPointer(start: buffer, count: count))
        return noErr
    }

    /// The device side of the unit's input: the rate the device records at.
    private static func deviceSampleRate(of unit: AudioUnit) throws -> Double {
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(
            AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &format, &size),
            "Reading the microphone format"
        )
        guard format.mSampleRate > 0, format.mChannelsPerFrame > 0 else {
            throw DictationError.microphoneUnavailable("The microphone has no usable format.")
        }
        return format.mSampleRate
    }

    /// Mono 32-bit float at `rate`; the unit mixes the device's channels into it.
    private static func monoFloat(_ rate: Double) -> AudioStreamBasicDescription {
        let bytes = UInt32(MemoryLayout<Float>.size)
        return AudioStreamBasicDescription(
            mSampleRate: rate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: bytes,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytes,
            mChannelsPerFrame: 1,
            mBitsPerChannel: bytes * 8,
            mReserved: 0
        )
    }

    private static func set(
        _ unit: AudioUnit, _ property: AudioUnitPropertyID, _ scope: AudioUnitScope,
        element: AudioUnitElement, to value: some Any
    ) throws {
        let status = withUnsafeBytes(of: value) { bytes in
            AudioUnitSetProperty(unit, property, scope, element, bytes.baseAddress, UInt32(bytes.count))
        }
        try check(status, "Setting up the microphone (property \(property))")
    }

    private static func check(_ status: OSStatus, _ step: String) throws {
        guard status != noErr else { return }
        throw DictationError.microphoneUnavailable("\(step) failed (\(status)).")
    }
}

/// Pavarotti: the rate a device runs at, which changes when Bluetooth headphones switch
/// to their headset profile.
enum DeviceSampleRate {
    static let address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    static func current(of device: AudioObjectID) -> Double? {
        var address = address
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr, rate > 0 else { return nil }
        return rate
    }
}
