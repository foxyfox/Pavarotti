import CoreAudio

// Pavarotti: choosing the output side of the voice-processing unit without
// disturbing a call that is already playing.
//
// VPIO is a duplex unit on one IO clock, so its output device must run at the
// microphone's rate. Upstream raises the default output's nominal rate to the
// mic rate. When a meeting app is already playing through that output (Safari
// or Chrome in a Google Meet call), the reclock mid-call shifts the pitch of
// what the user hears and breaks the meeting app's own echo cancellation, so the
// other participants hear themselves. While the default output is busy we
// therefore never reclock it: the unit's silent output goes to another device
// that already runs at the mic rate, or the rates stay as they are.

/// What a capture start may do with the output side of the VPIO unit.
enum VPIOOutputPlan: Equatable {
    /// The default output already runs at the mic rate.
    case useDefaultOutput
    /// The default output is idle; raise its rate to the mic rate (upstream path)
    /// and restore it on stop.
    case reclockDefaultOutput
    /// The default output is busy; send the unit's silent output to this device,
    /// which already runs at the mic rate. Nothing the user hears changes.
    case useCompanionOutput(AudioObjectID)
    /// The default output is busy and no device runs at the mic rate. Leave every
    /// rate alone and let the unit start as it can.
    case leaveRatesAlone
}

/// The facts about one output-capable device that the plan needs.
struct VPIOOutputCandidate: Equatable {
    let id: AudioObjectID
    let nominalRate: Double
    let outputChannels: UInt32
    let transportType: UInt32?
}

/// The default output as the plan sees it.
struct VPIODefaultOutput: Equatable {
    let id: AudioObjectID
    let rate: Double
    /// Another client is already running the device.
    let isBusy: Bool
}

enum VPIOOutputPlanner {
    /// Picks how to run the unit's output side.
    ///
    /// - Parameters:
    ///   - input: the microphone the unit records from, with its nominal rate.
    ///   - defaultOutput: the default output, its nominal rate, and whether another
    ///     client is already running it.
    ///   - candidates: every device with output streams, the default included.
    static func plan(
        input: (id: AudioObjectID, rate: Double),
        defaultOutput: VPIODefaultOutput,
        candidates: [VPIOOutputCandidate]
    ) -> VPIOOutputPlan {
        if abs(input.rate - defaultOutput.rate) <= 1 { return .useDefaultOutput }
        if !defaultOutput.isBusy { return .reclockDefaultOutput }
        if let companion = companion(
            inputID: input.id, inputRate: input.rate,
            excluding: defaultOutput.id, candidates: candidates
        ) {
            return .useCompanionOutput(companion)
        }
        return .leaveRatesAlone
    }

    /// A wired output that already runs at the mic rate. The microphone's own
    /// device comes first (a display or USB headset with speakers), then built-in
    /// speakers, then other wired devices. Wireless, virtual and aggregate devices
    /// are skipped: they can change profile, are not real hardware, or contain the
    /// device that is busy.
    static func companion(
        inputID: AudioObjectID,
        inputRate: Double,
        excluding defaultOutputID: AudioObjectID,
        candidates: [VPIOOutputCandidate]
    ) -> AudioObjectID? {
        let usable = candidates.filter { device in
            device.id != defaultOutputID
                && device.outputChannels > 0
                && abs(device.nominalRate - inputRate) <= 1
                && isWired(device.transportType)
        }
        func rank(_ device: VPIOOutputCandidate) -> Int {
            if device.id == inputID { return 0 }
            if device.transportType == kAudioDeviceTransportTypeBuiltIn { return 1 }
            return 2
        }
        return usable.min { rank($0) < rank($1) }?.id
    }

    private static func isWired(_ transport: UInt32?) -> Bool {
        guard let transport else { return false }
        let wired: Set<UInt32> = [
            kAudioDeviceTransportTypeBuiltIn,
            kAudioDeviceTransportTypeUSB,
            kAudioDeviceTransportTypeThunderbolt,
            kAudioDeviceTransportTypeDisplayPort,
            kAudioDeviceTransportTypeHDMI,
            kAudioDeviceTransportTypePCI,
            kAudioDeviceTransportTypeFireWire
        ]
        return wired.contains(transport)
    }
}
