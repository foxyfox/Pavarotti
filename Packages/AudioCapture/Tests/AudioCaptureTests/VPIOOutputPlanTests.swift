import CoreAudio
import Testing
@testable import AudioCapture

/// Pavarotti: the voice-processing output never reclocks a speaker a call is using.
@Suite("VPIO output plan")
struct VPIOOutputPlanTests {
    private let mic: AudioObjectID = 89
    private let speaker: AudioObjectID = 99

    private func device(
        _ id: AudioObjectID, rate: Double, channels: UInt32 = 2,
        transport: UInt32? = kAudioDeviceTransportTypeUSB
    ) -> VPIOOutputCandidate {
        VPIOOutputCandidate(id: id, nominalRate: rate, outputChannels: channels, transportType: transport)
    }

    private func plan(outputRate: Double, busy: Bool, candidates: [VPIOOutputCandidate]) -> VPIOOutputPlan {
        VPIOOutputPlanner.plan(
            input: (mic, 48000),
            defaultOutput: VPIODefaultOutput(id: speaker, rate: outputRate, isBusy: busy),
            candidates: candidates
        )
    }

    @Test("Matching rates leave the default output alone")
    func matchingRates() {
        #expect(plan(outputRate: 48000, busy: true, candidates: []) == .useDefaultOutput)
    }

    @Test("An idle output at another rate is reclocked as upstream does")
    func idleOutputIsReclocked() {
        #expect(plan(outputRate: 44100, busy: false, candidates: []) == .reclockDefaultOutput)
    }

    @Test("A busy output is never reclocked; the mic's own device takes the silent output")
    func busyOutputUsesMicDevice() {
        let candidates = [
            device(speaker, rate: 44100, transport: kAudioDeviceTransportTypeBluetooth),
            device(7, rate: 48000, transport: kAudioDeviceTransportTypeBuiltIn),
            device(mic, rate: 48000)
        ]
        #expect(plan(outputRate: 44100, busy: true, candidates: candidates) == .useCompanionOutput(mic))
    }

    @Test("Built-in speakers come before other wired devices")
    func builtInBeforeOtherWired() {
        let candidates = [
            device(5, rate: 48000, transport: kAudioDeviceTransportTypeUSB),
            device(7, rate: 48000, transport: kAudioDeviceTransportTypeBuiltIn)
        ]
        #expect(plan(outputRate: 44100, busy: true, candidates: candidates) == .useCompanionOutput(7))
    }

    @Test("Wireless, virtual, aggregate, wrong-rate and input-only devices are skipped")
    func unusableCompanions() {
        let candidates = [
            device(1, rate: 48000, transport: kAudioDeviceTransportTypeBluetooth),
            device(2, rate: 48000, transport: kAudioDeviceTransportTypeVirtual),
            device(3, rate: 48000, transport: kAudioDeviceTransportTypeAggregate),
            device(4, rate: 48000, transport: kAudioDeviceTransportTypeAirPlay),
            device(5, rate: 44100, transport: kAudioDeviceTransportTypeBuiltIn),
            device(6, rate: 48000, channels: 0, transport: kAudioDeviceTransportTypeBuiltIn),
            device(8, rate: 48000, transport: nil)
        ]
        #expect(plan(outputRate: 44100, busy: true, candidates: candidates) == .leaveRatesAlone)
    }

    @Test("The busy default output itself is never picked as companion")
    func defaultNeverCompanion() {
        let candidates = [device(speaker, rate: 48000, transport: kAudioDeviceTransportTypeBuiltIn)]
        #expect(plan(outputRate: 44100, busy: true, candidates: candidates) == .leaveRatesAlone)
    }
}
