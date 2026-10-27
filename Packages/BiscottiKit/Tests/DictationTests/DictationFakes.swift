import CohereTranscribe
import Foundation
import Synchronization
@testable import Dictation

/// Hands out recorded samples and lets the test decide when "audio arrives".
final class FakeAudioSource: DictationAudioSource {
    var samples: [Float] = []
    var startError: (any Error)?
    private(set) var startCount = 0
    private(set) var cancelCount = 0
    private var onFirstAudio: (@Sendable () -> Void)?

    func start(onFirstAudio: @escaping @Sendable () -> Void) throws {
        if let startError {
            throw startError
        }
        startCount += 1
        self.onFirstAudio = onFirstAudio
    }

    func stop() -> [Float] {
        onFirstAudio = nil
        return samples
    }

    func cancel() {
        cancelCount += 1
    }

    /// Simulates the microphone's first buffer. Still fires after a cancel, like a late
    /// buffer from the audio thread would.
    func deliverFirstAudio() {
        onFirstAudio?()
    }

    /// `seconds` of silence at the dictation sample rate.
    static func silence(seconds: Double) -> [Float] {
        Array(repeating: 0, count: Int(seconds * Double(DictationAudio.sampleRate)))
    }
}

/// A transcription engine that returns canned text.
final class FakeEngine: DictationTranscribing {
    struct Request: Equatable {
        let sampleCount: Int
        let sampleRate: Int
        let language: TranscriptionLanguage
        let modelID: String
    }

    struct State {
        var isInstalled = true
        var text = "  Hallo Welt \n"
        var error: (any Error)?
        var requests: [Request] = []
        var prepared: [String] = []
        var installed: [String] = []
        var shutdownCount = 0
    }

    let state = Mutex(State())

    func isInstalled(modelID _: String) -> Bool {
        state.withLock { $0.isInstalled }
    }

    func install(modelID: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        progress(0.5)
        progress(1)
        state.withLock { current in
            current.installed.append(modelID)
            current.isInstalled = true
        }
    }

    func prepare(modelID: String) async throws {
        state.withLock { $0.prepared.append(modelID) }
    }

    func transcribe(
        samples: [Float],
        sampleRate: Int,
        language: TranscriptionLanguage,
        modelID: String
    ) async throws -> String {
        let request = Request(sampleCount: samples.count, sampleRate: sampleRate, language: language, modelID: modelID)
        let outcome = state.withLock { current -> Result<String, any Error> in
            current.requests.append(request)
            if let error = current.error {
                return .failure(error)
            }
            return .success(current.text)
        }
        return try outcome.get()
    }

    func shutdown() async {
        state.withLock { $0.shutdownCount += 1 }
    }
}

@MainActor
final class FakeInserter: TextInserting {
    var result = TextInsertionResult.pasted
    private(set) var inserted: [String] = []
    private(set) var restoredClipboard: [Bool] = []

    func insert(_ text: String, restoringClipboard: Bool) async -> TextInsertionResult {
        inserted.append(text)
        restoredClipboard.append(restoringClipboard)
        return result
    }
}

@MainActor
final class FakeSounds: SoundCuePlaying {
    /// What `play` reports as the sound's length.
    var length: TimeInterval?
    private(set) var played: [SoundChoice] = []

    func play(_ choice: SoundChoice) -> TimeInterval? {
        played.append(choice)
        return length
    }
}

@MainActor
final class FakeDucker: OutputDucking {
    private(set) var levels: [Double] = []
    private(set) var restoreCount = 0

    func duck(to level: Double) {
        levels.append(level)
    }

    func restore() {
        restoreCount += 1
    }
}

@MainActor
final class FakeAccessibility: AccessibilityTrust {
    var isTrusted = true
    private(set) var requestCount = 0

    func requestTrust() {
        requestCount += 1
    }
}

/// Records watches and lets the test report a correction.
@MainActor
final class FakeCorrectionWatcher: CorrectionWatching {
    private(set) var watched: [String] = []
    private(set) var finishCount = 0
    private(set) var stopCount = 0
    private var onCorrection: (@MainActor (DetectedCorrection) -> Void)?

    func watch(inserted: String, onCorrection: @escaping @MainActor (DetectedCorrection) -> Void) {
        watched.append(inserted)
        self.onCorrection = onCorrection
    }

    func finish() {
        finishCount += 1
    }

    func stop() {
        stopCount += 1
        onCorrection = nil
    }

    /// Simulates the user fixing a word in the watched field.
    func report(_ correction: DetectedCorrection) {
        onCorrection?(correction)
    }
}

@MainActor
final class TestClock {
    var now: TimeInterval = 0
}

@MainActor
final class Counter {
    var value = 0
}

/// A controller wired to fakes, with its own user defaults and sound folder.
@MainActor
final class DictationHarness {
    let audio = FakeAudioSource()
    let engine = FakeEngine()
    let inserter = FakeInserter()
    let sounds = FakeSounds()
    let ducker = FakeDucker()
    let accessibility = FakeAccessibility()
    let clock = TestClock()
    let dictionary = PersonalDictionary(fileURL: nil)
    let corrections = FakeCorrectionWatcher()
    let defaults: UserDefaults
    let soundFolder: URL
    let controller: DictationController
    private let suiteName: String

    init(configure: (inout DictationSettings) -> Void = { _ in }) {
        suiteName = "pavarotti.tests.controller.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName) ?? .standard
        soundFolder = FileManager.default.temporaryDirectory.appending(path: "pavarotti-harness-\(UUID().uuidString)")
        var settings = DictationSettings()
        configure(&settings)
        let store = DictationSettingsStore(defaults: defaults)
        store.save(settings)
        let dependencies = DictationDependencies(
            audio: audio,
            engine: engine,
            inserter: inserter,
            sounds: sounds,
            ducker: ducker,
            accessibility: accessibility,
            soundLibrary: SoundLibrary(directory: soundFolder),
            dictionary: dictionary,
            corrections: corrections
        )
        let clock = clock
        controller = DictationController(store: store, dependencies: dependencies) { clock.now }
    }

    func tearDown() {
        controller.cancel()
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: soundFolder)
    }

    /// Starts listening, delivers the first audio and waits until the start cue played.
    func startListening() async -> Bool {
        controller.start()
        audio.deliverFirstAudio()
        let expected = controller.settings.playsSounds ? 1 : 0
        return await eventually { self.sounds.played.count >= expected }
    }
}

/// Polls `condition` on the main actor until it holds or `timeout` passes.
@MainActor
func eventually(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
        guard clock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}
