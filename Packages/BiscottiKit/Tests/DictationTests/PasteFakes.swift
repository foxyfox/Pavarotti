import AppKit
@testable import Dictation

extension RemoteClipboardSyncApplication {
    static var screenSharing: RemoteClipboardSyncApplication {
        RemoteClipboardSyncApplication(processIdentifier: 501, bundleIdentifier: "com.apple.ScreenSharing")
    }

    static var windowsApp: RemoteClipboardSyncApplication {
        RemoteClipboardSyncApplication(processIdentifier: 502, bundleIdentifier: "com.microsoft.rdc.macos")
    }

    static var pavarotti: RemoteClipboardSyncApplication {
        RemoteClipboardSyncApplication(processIdentifier: 500, bundleIdentifier: "de.foxagon.pavarotti")
    }

    static var textEdit: RemoteClipboardSyncApplication {
        RemoteClipboardSyncApplication(processIdentifier: 600, bundleIdentifier: "com.apple.TextEdit")
    }
}

/// Activations without windows: records what the nudge did and moves the frontmost app.
@MainActor
final class FakeSyncEnvironment: RemoteClipboardSyncEnvironment {
    var frontmost: RemoteClipboardSyncApplication?
    var isActive = false
    var isRegular = false
    var spaceChanges = 0
    /// Activations of the remote app that leave it behind before one brings it to the front.
    var ignoredActivations = 0
    /// Runs when Pavarotti takes over, like Windows App sending the remote clipboard then.
    var onActivatePavarotti: (@MainActor () -> Void)?
    /// Runs when the remote app is activated again.
    var onActivate: (@MainActor () -> Void)?
    private(set) var calls: [String] = []

    init(frontmost: RemoteClipboardSyncApplication? = .screenSharing) {
        self.frontmost = frontmost
    }

    func note(_ call: String) {
        calls.append(call)
    }

    func frontmostApplication() -> RemoteClipboardSyncApplication? {
        frontmost
    }

    func isPavarottiActive() -> Bool {
        isActive
    }

    func usesRegularActivationPolicy() -> Bool {
        isRegular
    }

    func activeSpaceChangeCount() -> Int {
        spaceChanges
    }

    func activatePavarotti(over _: RemoteClipboardSyncApplication) {
        calls.append("activatePavarotti")
        isActive = true
        frontmost = .pavarotti
        onActivatePavarotti?()
    }

    func activate(_ application: RemoteClipboardSyncApplication) -> Bool {
        calls.append("activate")
        onActivate?()
        guard ignoredActivations == 0 else {
            ignoredActivations -= 1
            return true
        }
        isActive = false
        frontmost = application
        return true
    }

    func removeHelperWindow() {
        calls.append("removeHelperWindow")
    }

    func removeHelperWindowWhenPavarottiResignsActive() {
        calls.append("removeHelperWindowLater")
    }
}

/// A sleep that returns at once and records its pauses. `cancelsCall` makes that call (from 1)
/// throw, as a cancelled `Task.sleep` does.
@MainActor
final class FakeSleep {
    private(set) var pauses: [Duration] = []
    var cancelsCall: Int?

    func record(_ duration: Duration) throws {
        pauses.append(duration)
        if pauses.count == cancelsCall {
            throw CancellationError()
        }
    }

    var closure: RemoteClipboardSyncNudger.Sleep {
        { [self] duration in try record(duration) }
    }
}

/// Records the key events instead of posting them.
final class FakeKeyPoster: SyntheticKeyEventPosting, @unchecked Sendable {
    struct Posting: Equatable {
        let events: [SyntheticKeyEvent]
        let options: SyntheticKeyEventPostingOptions
    }

    private let lock = NSLock()
    private var postings: [Posting] = []

    func enqueue(
        _ events: [SyntheticKeyEvent],
        options: SyntheticKeyEventPostingOptions,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        lock.withLock { postings.append(Posting(events: events, options: options)) }
        completion(true)
    }

    var all: [Posting] {
        lock.withLock { postings }
    }
}

/// An inserter wired to a private pasteboard, a recording poster and a fake environment.
@MainActor
final class PasteHarness {
    let pasteboard = NSPasteboard.withUniqueName()
    let trust = FakeAccessibility()
    let poster = FakeKeyPoster()
    let environment: FakeSyncEnvironment
    let sleeper = FakeSleep()
    var frontmost: String?
    var nudgeSettings = RemoteClipboardSyncNudgeSettings()
    var keyboardSettings = SyntheticKeyboardSettings()
    private(set) lazy var inserter = makeInserter()

    init(frontmost: RemoteClipboardSyncApplication? = .screenSharing) {
        environment = FakeSyncEnvironment(frontmost: frontmost)
        self.frontmost = frontmost?.bundleIdentifier
    }

    func tearDown() {
        pasteboard.releaseGlobally()
    }

    /// Puts the user's clipboard in place.
    func copy(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    var clipboard: String? {
        pasteboard.string(forType: .string)
    }

    private func makeInserter() -> PasteboardTextInserter {
        let system = PasteSystem(
            poster: poster,
            frontmostBundleIdentifier: { [unowned self] in frontmost },
            keyboardSettings: { [unowned self] in keyboardSettings },
            additionalRemoteBundleIdentifiers: { [] },
            keyboardType: { 40 },
            sleep: sleeper.closure
        )
        let nudger = RemoteClipboardSyncNudger(
            environment: environment,
            settingsProvider: { [unowned self] in nudgeSettings },
            sleep: sleeper.closure
        )
        return PasteboardTextInserter(pasteboard: pasteboard, trust: trust, system: system, nudger: nudger)
    }
}
