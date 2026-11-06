import CoreAudio

// Pavarotti: finding the microphone chosen in Settings and the devices a capture
// may use without disturbing a call, kept out of upstream's helpers.
extension CoreAudioHelpers {
    /// Every audio device the HAL currently lists.
    static func allDeviceIDs() -> [AudioObjectID] {
        getPropertyArray(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            address: AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            type: AudioObjectID.self
        )
    }

    /// The connected device with the persistent UID `uid`, `nil` when none is.
    static func deviceID(forUID uid: String) -> AudioObjectID? {
        allDeviceIDs().first { deviceUID(for: $0) == uid }
    }

    /// Whether any client (another app, or this one) is running IO on the device.
    static func isRunningSomewhere(_ deviceID: AudioObjectID) -> Bool {
        let running = getPropertyData(
            objectID: deviceID,
            address: AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            type: UInt32.self
        )
        return (running ?? 0) != 0
    }

    /// Every device with output streams, described for `VPIOOutputPlanner`.
    static func outputCandidates() -> [VPIOOutputCandidate] {
        allDeviceIDs().compactMap { id in
            guard let channels = channelCount(for: id, scope: kAudioObjectPropertyScopeOutput),
                  channels > 0,
                  let rate = nominalSampleRate(for: id)
            else { return nil }
            return VPIOOutputCandidate(
                id: id, nominalRate: rate, outputChannels: channels,
                transportType: transportType(for: id)
            )
        }
    }
}
