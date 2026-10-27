import CoreAudio
import Testing
@testable import AudioCapture

/// Pavarotti: finding the chosen microphone by its persistent UID.
@Suite("Core Audio device lookup")
struct CoreAudioDeviceLookupTests {
    @Test("An unknown UID finds no device")
    func unknownUID() {
        #expect(CoreAudioHelpers.deviceID(forUID: "pavarotti.tests.no-such-device") == nil)
    }

    @Test("Every connected device is found again by its UID")
    func connectedDevices() {
        let devices = CoreAudioHelpers.getPropertyArray(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            address: AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            type: AudioObjectID.self
        )
        for device in devices {
            guard let uid = CoreAudioHelpers.deviceUID(for: device) else { continue }
            #expect(CoreAudioHelpers.deviceID(forUID: uid) == device)
        }
    }
}
