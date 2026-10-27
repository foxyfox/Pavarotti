import CoreAudio

// Pavarotti: finding the microphone chosen in Settings, kept out of upstream's helpers.
extension CoreAudioHelpers {
    /// The connected device with the persistent UID `uid`, `nil` when none is.
    static func deviceID(forUID uid: String) -> AudioObjectID? {
        let devices = getPropertyArray(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            address: AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            type: AudioObjectID.self
        )
        return devices.first { deviceUID(for: $0) == uid }
    }
}
