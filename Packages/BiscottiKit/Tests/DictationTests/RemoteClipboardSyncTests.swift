import Foundation
import Testing
@testable import Dictation

@Suite("Remote session classifier")
struct RemoteSessionClassifierTests {
    @Test("Screen Sharing, Windows App and RustDesk are recognized, case-insensitively")
    func knownClients() {
        #expect(RemoteSessionClassifier.classify(bundleIdentifier: "com.apple.ScreenSharing") == .macScreenSharing)
        #expect(RemoteSessionClassifier.classify(bundleIdentifier: "com.microsoft.rdc.macos") == .windowsRemoteDesktop)
        #expect(RemoteSessionClassifier.classify(bundleIdentifier: "com.microsoft.rdc") == .windowsRemoteDesktop)
        #expect(RemoteSessionClassifier.classify(bundleIdentifier: " com.carriez.RustDesk ") == .genericRemote)
    }

    @Test("other apps and look-alike prefixes are local")
    func localApps() {
        #expect(RemoteSessionClassifier.classify(bundleIdentifier: "com.apple.TextEdit") == nil)
        #expect(RemoteSessionClassifier.classify(bundleIdentifier: "com.microsoft.rdcx") == nil)
        #expect(RemoteSessionClassifier.classify(bundleIdentifier: "") == nil)
        #expect(RemoteSessionClassifier.classify(bundleIdentifier: nil) == nil)
    }

    @Test("extra bundle identifiers from the hidden default count as remote")
    func additionalIdentifiers() throws {
        let suite = "pavarotti.tests.remote.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["com.example.Viewer"], forKey: "remoteInsertionAdditionalBundleIdentifiers")

        let extra = RemoteSessionClassifier.additionalBundleIdentifiers(from: defaults)
        #expect(RemoteSessionClassifier.classify(bundleIdentifier: "com.example.viewer", additionalBundleIdentifiers: extra) == .genericRemote)
        #expect(RemoteSessionClassifier.classify(bundleIdentifier: "com.example.other", additionalBundleIdentifiers: extra) == nil)
    }
}

@Suite("Remote clipboard sync nudge")
@MainActor
struct RemoteClipboardSyncNudgerTests {
    private func makeNudger(
        _ environment: FakeSyncEnvironment?,
        sleeper: FakeSleep,
        settings: RemoteClipboardSyncNudgeSettings = RemoteClipboardSyncNudgeSettings()
    ) -> RemoteClipboardSyncNudger {
        RemoteClipboardSyncNudger(environment: environment, settingsProvider: { settings }, sleep: sleeper.closure)
    }

    @Test("Pavarotti is active while the text is written, then the remote app comes back")
    func nudgeOrder() async {
        let environment = FakeSyncEnvironment()
        let sleeper = FakeSleep()
        let nudger = makeNudger(environment, sleeper: sleeper)

        let outcome = await nudger.nudge(expectedBundleIdentifier: "com.apple.screensharing") {
            environment.note("write")
        }

        #expect(outcome == .nudged(.screenSharing))
        #expect(environment.calls == ["activatePavarotti", "write", "activate", "removeHelperWindow"])
        #expect(sleeper.pauses == [.milliseconds(150), .milliseconds(150), .milliseconds(300)])
        #expect(nudger.isFrontmost(.screenSharing))
    }

    @Test("a disabled nudge, a missing environment and another app in front do nothing")
    func nothingToDo() async {
        let sleeper = FakeSleep()
        var settings = RemoteClipboardSyncNudgeSettings()
        settings.isEnabled = false
        let environment = FakeSyncEnvironment()

        let disabled = await makeNudger(environment, sleeper: sleeper, settings: settings)
            .nudge(expectedBundleIdentifier: "com.apple.ScreenSharing") { environment.note("write") }
        let unavailable = await makeNudger(nil, sleeper: sleeper)
            .nudge(expectedBundleIdentifier: "com.apple.ScreenSharing") { environment.note("write") }
        let elsewhere = await makeNudger(environment, sleeper: sleeper)
            .nudge(expectedBundleIdentifier: "com.microsoft.rdc.macos") { environment.note("write") }

        #expect(disabled == .disabled)
        #expect(unavailable == .unavailable)
        #expect(elsewhere == .frontmostApplicationChanged)
        #expect(environment.calls.isEmpty)
        #expect(sleeper.pauses.isEmpty)
    }

    @Test("while Pavarotti shows a window, the nudge can be switched off")
    func regularActivationPolicy() async {
        let environment = FakeSyncEnvironment()
        environment.isRegular = true
        var settings = RemoteClipboardSyncNudgeSettings()
        settings.nudgesWhenRegular = false

        let outcome = await makeNudger(environment, sleeper: FakeSleep(), settings: settings)
            .nudge(expectedBundleIdentifier: "com.apple.ScreenSharing") {}

        #expect(outcome == .skippedForRegularActivationPolicy)
        #expect(environment.calls.isEmpty)
    }

    @Test("cancelling during the self-activation skips the write but brings the remote app back")
    func cancelled() async {
        let environment = FakeSyncEnvironment()
        let sleeper = FakeSleep()
        sleeper.cancelsCall = 1

        let outcome = await makeNudger(environment, sleeper: sleeper)
            .nudge(expectedBundleIdentifier: "com.apple.ScreenSharing") { environment.note("write") }

        #expect(outcome == .cancelled)
        #expect(environment.calls == ["activatePavarotti", "activate", "removeHelperWindow"])
        #expect(sleeper.pauses == [.milliseconds(150), .milliseconds(150)])
    }

    @Test("a remote app that stays behind is activated once more and polled")
    func reactivationRetry() async {
        let environment = FakeSyncEnvironment()
        environment.ignoredActivations = 1
        let sleeper = FakeSleep()

        let outcome = await makeNudger(environment, sleeper: sleeper)
            .nudge(expectedBundleIdentifier: "com.apple.ScreenSharing") {}

        #expect(outcome == .nudged(.screenSharing))
        #expect(environment.calls == ["activatePavarotti", "activate", "activate", "removeHelperWindow"])
    }

    @Test("a remote app that never comes back is reported and the helper window waits")
    func remoteStaysBehind() async {
        let environment = FakeSyncEnvironment()
        environment.ignoredActivations = 2
        let sleeper = FakeSleep()
        let nudger = makeNudger(environment, sleeper: sleeper)

        let outcome = await nudger.nudge(expectedBundleIdentifier: "com.apple.ScreenSharing") {}

        #expect(outcome == .nudged(.screenSharing))
        #expect(!nudger.isFrontmost(.screenSharing))
        #expect(environment.calls.last == "removeHelperWindowLater")
        // Ten polls of 25 ms fill the 250 ms retry window.
        #expect(sleeper.pauses.count(where: { $0 == .milliseconds(25) }) == 10)
    }

    @Test("pauses come from the hidden defaults, within 0 to 5 seconds")
    func settingsFromDefaults() throws {
        let suite = "pavarotti.tests.nudge.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(RemoteClipboardSyncNudgeSettings.load(from: defaults) == RemoteClipboardSyncNudgeSettings())

        defaults.set(false, forKey: "remoteClipboardSyncNudgeEnabled")
        defaults.set(false, forKey: "remoteClipboardSyncNudgeWhenRegular")
        defaults.set(200, forKey: "remoteClipboardSyncNudgeSelfActivationMilliseconds")
        defaults.set(-1, forKey: "remoteClipboardSyncNudgeReactivationMilliseconds")
        defaults.set(9000, forKey: "remoteClipboardSyncNudgePasteDelayMilliseconds")
        let settings = RemoteClipboardSyncNudgeSettings.load(from: defaults)

        #expect(!settings.isEnabled)
        #expect(!settings.nudgesWhenRegular)
        #expect(settings.selfActivationDuration == .milliseconds(200))
        #expect(settings.reactivationDuration == .milliseconds(150))
        #expect(settings.pasteDelay == .milliseconds(300))
    }
}
