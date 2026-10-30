import AppKit
import Testing
@testable import Dictation

/// kVK_ANSI_V.
private let keyV: CGKeyCode = 9

@Suite("Pasting", .serialized)
@MainActor
struct PasteboardTextInserterTests {
    // MARK: - Local apps

    @Test("a local paste sends the chord with local timing and restores the clipboard")
    func localPaste() async {
        let harness = PasteHarness(frontmost: .textEdit)
        defer { harness.tearDown() }
        harness.copy("Vorher")

        let result = await harness.inserter.insert("Hallo Welt", restoringClipboard: true)

        #expect(result == .pasted)
        #expect(harness.poster.all == [FakeKeyPoster.Posting(
            events: SyntheticKeyEvent.commandChord(keyCode: keyV, timing: .local),
            options: .pasteChord(settings: SyntheticKeyboardSettings(), keyboardType: 40)
        )])
        #expect(harness.sleeper.pauses == [.milliseconds(400)])
        #expect(harness.clipboard == "Vorher")
        #expect(harness.environment.calls.isEmpty)
    }

    @Test("without restoring, the text stays on the clipboard")
    func keepsText() async {
        let harness = PasteHarness(frontmost: .textEdit)
        defer { harness.tearDown() }
        harness.copy("Vorher")

        #expect(await harness.inserter.insert("Hallo Welt", restoringClipboard: false) == .pasted)
        #expect(harness.clipboard == "Hallo Welt")
        #expect(harness.sleeper.pauses.isEmpty)
        let types = harness.pasteboard.pasteboardItems?.first?.types ?? []
        #expect(types.contains(PasteboardTextInserter.transientType))
    }

    @Test("the hidden default goes back to the flags-only ⌘V")
    func flagsOnly() async {
        let harness = PasteHarness(frontmost: .textEdit)
        defer { harness.tearDown() }
        harness.keyboardSettings.chordEnabled = false

        #expect(await harness.inserter.insert("Hallo", restoringClipboard: false) == .pasted)
        #expect(harness.poster.all == [FakeKeyPoster.Posting(
            events: SyntheticKeyEvent.flagsOnly(keyCode: keyV),
            options: .flagsOnlyPaste
        )])
    }

    @Test("without Accessibility the text is only copied")
    func untrusted() async {
        let harness = PasteHarness(frontmost: .textEdit)
        defer { harness.tearDown() }
        harness.trust.isTrusted = false

        #expect(await harness.inserter.insert("Hallo", restoringClipboard: true) == .copiedOnly)
        #expect(harness.clipboard == "Hallo")
        #expect(harness.poster.all.isEmpty)
    }

    // MARK: - Remote desktops

    @Test("a remote paste syncs the clipboard first, pastes slowly and restores later")
    func remotePaste() async {
        let harness = PasteHarness(frontmost: .screenSharing)
        defer { harness.tearDown() }
        harness.copy("Vorher")

        let result = await harness.inserter.insert("Hallo Welt", restoringClipboard: true)

        #expect(result == .pasted)
        #expect(harness.environment.calls == ["activatePavarotti", "activate", "removeHelperWindow"])
        #expect(harness.poster.all.map(\.events) == [SyntheticKeyEvent.commandChord(keyCode: keyV, timing: .remote)])
        #expect(harness.sleeper.pauses == [.milliseconds(150), .milliseconds(150), .milliseconds(300), .milliseconds(1500)])
        #expect(harness.clipboard == "Vorher")
    }

    @Test("what the remote client sent when it lost focus is the clipboard that comes back")
    func remoteClipboardIsSaved() async {
        let harness = PasteHarness(frontmost: .windowsApp)
        defer { harness.tearDown() }
        harness.copy("Vorher")
        harness.environment.onActivatePavarotti = { harness.copy("Aus Windows") }

        #expect(await harness.inserter.insert("Hallo Welt", restoringClipboard: true) == .pasted)
        #expect(harness.clipboard == "Aus Windows")
    }

    @Test("a disabled nudge still pastes into the remote desktop")
    func remoteWithoutNudge() async {
        let harness = PasteHarness(frontmost: .screenSharing)
        defer { harness.tearDown() }
        harness.nudgeSettings.isEnabled = false

        #expect(await harness.inserter.insert("Hallo", restoringClipboard: false) == .pasted)
        #expect(harness.environment.calls.isEmpty)
        #expect(harness.poster.all.map(\.events) == [SyntheticKeyEvent.commandChord(keyCode: keyV, timing: .remote)])
        #expect(harness.clipboard == "Hallo")
    }

    @Test("when another app is in front, nothing is pasted and the text is on the clipboard")
    func remoteWindowGone() async {
        let harness = PasteHarness(frontmost: .screenSharing)
        defer { harness.tearDown() }
        harness.environment.frontmost = .textEdit
        harness.copy("Vorher")

        #expect(await harness.inserter.insert("Hallo", restoringClipboard: true) == .notPasted(.remoteWindowNotInFront))
        #expect(harness.poster.all.isEmpty)
        #expect(harness.clipboard == "Hallo")
    }

    @Test("a remote app that does not come back gets no paste")
    func remoteStaysBehind() async {
        let harness = PasteHarness(frontmost: .screenSharing)
        defer { harness.tearDown() }
        harness.environment.ignoredActivations = 100

        #expect(await harness.inserter.insert("Hallo", restoringClipboard: true) == .notPasted(.remoteWindowNotInFront))
        #expect(harness.poster.all.isEmpty)
        #expect(harness.clipboard == "Hallo")
    }

    @Test("a clipboard change during the sync repeats it once")
    func clipboardChangedOnce() async {
        let harness = PasteHarness(frontmost: .screenSharing)
        defer { harness.tearDown() }
        var changes = 0
        harness.environment.onActivate = {
            guard changes == 0 else { return }
            changes += 1
            harness.copy("Dazwischen")
        }

        #expect(await harness.inserter.insert("Hallo", restoringClipboard: false) == .pasted)
        #expect(harness.environment.calls.count(where: { $0 == "activatePavarotti" }) == 2)
        #expect(harness.poster.all.count == 1)
        #expect(harness.clipboard == "Hallo")
    }

    @Test("a second clipboard change skips the paste")
    func clipboardChangedTwice() async {
        let harness = PasteHarness(frontmost: .screenSharing)
        defer { harness.tearDown() }
        harness.environment.onActivate = { harness.copy("Dazwischen") }

        #expect(await harness.inserter.insert("Hallo", restoringClipboard: true) == .notPasted(.clipboardChanged))
        #expect(harness.poster.all.isEmpty)
        #expect(harness.clipboard == "Dazwischen")
    }

    @Test("cancelling before the text was written leaves the clipboard alone")
    func cancelledEarly() async {
        let harness = PasteHarness(frontmost: .screenSharing)
        defer { harness.tearDown() }
        harness.copy("Vorher")
        harness.sleeper.cancelsCall = 1

        #expect(await harness.inserter.insert("Hallo", restoringClipboard: true) == .notPasted(.cancelled))
        #expect(harness.poster.all.isEmpty)
        #expect(harness.clipboard == "Vorher")
    }

    @Test("cancelling after the text was written puts the clipboard back")
    func cancelledLate() async {
        let harness = PasteHarness(frontmost: .screenSharing)
        defer { harness.tearDown() }
        harness.copy("Vorher")
        // Self-activation, reactivation, then the paste delay is cancelled.
        harness.sleeper.cancelsCall = 3

        #expect(await harness.inserter.insert("Hallo", restoringClipboard: true) == .notPasted(.cancelled))
        #expect(harness.poster.all.isEmpty)
        #expect(harness.clipboard == "Vorher")
    }
}

@Suite("Remote paste in the controller")
@MainActor
struct DictationRemotePasteTests {
    @Test("a skipped remote paste is reported, a cancelled one is not")
    func notPasted() async {
        let cases: [(PasteSkipReason, String?)] = [
            (.remoteWindowNotInFront, PasteSkipReason.remoteWindowNotInFront.message),
            (.cancelled, nil)
        ]
        for (reason, expected) in cases {
            let harness = DictationHarness()
            defer { harness.tearDown() }
            harness.inserter.result = .notPasted(reason)

            #expect(await harness.startListening())
            harness.audio.samples = FakeAudioSource.speech(seconds: 1)
            harness.controller.stop()
            await harness.controller.waitForWork()

            if let expected {
                #expect(harness.controller.phase == .failed(expected))
            } else {
                #expect(harness.controller.phase == .idle)
            }
            #expect(harness.controller.history.entries.map(\.text) == ["Hallo Welt"])
        }
    }
}
