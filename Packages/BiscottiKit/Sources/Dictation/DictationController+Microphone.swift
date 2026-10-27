import Foundation

// Pavarotti: the microphone choice and the permission to record it.

public extension DictationController {
    /// Re-reads the connected input devices, the system default and the permission, for
    /// Settings.
    func refreshMicrophones() {
        microphones = dependencies.microphones.devices()
        defaultMicrophone = dependencies.microphones.defaultDevice()
        microphonePermission = dependencies.microphones.permission
    }

    /// Records from `device` from the next dictation on. `nil` follows the system default.
    func chooseMicrophone(_ device: MicrophoneDevice?) {
        update { $0.microphone = device }
    }

    /// Whether the chosen microphone is connected. Always `true` for the system default.
    /// A disconnected choice is kept; dictation records from the system default meanwhile.
    var isChosenMicrophoneConnected: Bool {
        guard let chosen = settings.microphone else { return true }
        return microphones.contains { $0.id == chosen.id }
    }

    /// Shows the system prompt for microphone access when it was not asked yet. Tells the
    /// user when access is denied.
    func requestMicrophonePermission() {
        guard microphoneRequest == nil else { return }
        microphoneRequest = Task { [weak self] in
            let granted = await self?.dependencies.microphones.requestPermission() ?? false
            guard let self else { return }
            microphoneRequest = nil
            microphonePermission = dependencies.microphones.permission
            if !granted {
                fail(DictationError.microphoneDenied.localizedDescription)
            }
        }
    }
}

extension DictationController {
    /// Whether the microphone may record now. Without permission macOS records silence
    /// instead of failing, so this asks first. The press that asks does not start
    /// listening; the next one does.
    func mayRecord() -> Bool {
        microphonePermission = dependencies.microphones.permission
        switch microphonePermission {
        case .granted:
            return true
        case .denied:
            fail(DictationError.microphoneDenied.localizedDescription)
            return false
        case .undecided:
            requestMicrophonePermission()
            return false
        }
    }

    /// Waits for a running permission request. For tests.
    func waitForMicrophoneRequest() async {
        await microphoneRequest?.value
    }
}
