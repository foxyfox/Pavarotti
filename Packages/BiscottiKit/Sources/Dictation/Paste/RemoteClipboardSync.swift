import Foundation
import os

// Pavarotti: makes Screen Sharing and Windows App send the clipboard to the remote computer
// before a paste. Ported from Andreas's TypeWhisper fork (2ee8994, "Sync the clipboard to
// remote sessions before pasting").
//
// With a shared clipboard, both clients only transfer the local clipboard when their window
// becomes active. The first dictation after switching to the remote window therefore pastes
// the new text, every further one in the same window pastes the clipboard of the first.
// Waiting does not help, and "Edit > Send Clipboard" is disabled while the clipboard is shared.
//
// What works (measured with both clients, full-screen remote window on its own Space):
// Pavarotti becomes the active app for a moment, then the remote app is activated again and
// gets a short pause before the paste chord. The payload is written while Pavarotti is active:
// Windows App sends the remote clipboard to this Mac when its window loses focus, which would
// replace a payload written before, and takes the local clipboard when it is activated again.
// Pavarotti may have a window open on another Space, and activating it could switch there, so
// it first shows an invisible helper window on the active Space and makes it key.

/// An application the nudge activates again.
struct RemoteClipboardSyncApplication: Equatable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
}

enum RemoteClipboardSyncNudgeOutcome: Equatable {
    /// The hidden `remoteClipboardSyncNudgeEnabled` default is off.
    case disabled
    /// No system environment: nothing was activated.
    case unavailable
    /// Pavarotti shows a window (regular activation policy) and the hidden
    /// `remoteClipboardSyncNudgeWhenRegular` default is off: nothing was activated.
    case skippedForRegularActivationPolicy
    /// The frontmost app is not the expected remote app; nothing was activated.
    case frontmostApplicationChanged
    /// Pavarotti was active for a moment and the remote app was activated again. It may still
    /// not be in front, see `RemoteClipboardSyncNudger.isFrontmost(_:)`.
    case nudged(RemoteClipboardSyncApplication)
    /// Cancelled. If Pavarotti had already taken over, the remote app was activated again.
    case cancelled
}

/// Hidden settings without UI, for example
/// `defaults write de.foxagon.pavarotti remoteClipboardSyncNudgeEnabled -bool NO` pastes without
/// the nudge, and `remoteClipboardSyncNudgeWhenRegular -bool NO` does so only while Pavarotti
/// shows a window. Pauses are read in milliseconds from
/// `remoteClipboardSyncNudgeSelfActivationMilliseconds`,
/// `remoteClipboardSyncNudgeReactivationMilliseconds` and
/// `remoteClipboardSyncNudgePasteDelayMilliseconds`.
struct RemoteClipboardSyncNudgeSettings: Equatable {
    /// Upper bound of a pause read from the hidden defaults.
    static let maximumPause = Duration.seconds(5)

    var isEnabled = true
    /// How long Pavarotti stays the active app.
    var selfActivationDuration = Duration.milliseconds(150)
    /// Pause after activating the remote app again, before the helper window goes.
    var reactivationDuration = Duration.milliseconds(150)
    /// Pause after that before the paste chord, while the client sends the clipboard.
    var pasteDelay = Duration.milliseconds(300)
    /// Whether the nudge still runs while Pavarotti shows a window. Activating a regular app
    /// may switch to the Space of its window.
    var nudgesWhenRegular = true
    /// When the remote app is not in front after the reactivation pause, it is brought to the
    /// front every `reactivationRetryInterval` and checked every `reactivationRetryPollInterval`
    /// for up to `reactivationRetryTimeout`. A Space or display switch can take that long.
    var reactivationRetryPollInterval = Duration.milliseconds(25)
    var reactivationRetryInterval = Duration.milliseconds(100)
    var reactivationRetryTimeout = Duration.seconds(1)

    static func load(from defaults: UserDefaults) -> RemoteClipboardSyncNudgeSettings {
        var settings = RemoteClipboardSyncNudgeSettings()
        if let enabled = defaults.object(forKey: "remoteClipboardSyncNudgeEnabled") as? Bool {
            settings.isEnabled = enabled
        }
        if let whenRegular = defaults.object(forKey: "remoteClipboardSyncNudgeWhenRegular") as? Bool {
            settings.nudgesWhenRegular = whenRegular
        }
        if let pause = pause(forKey: "remoteClipboardSyncNudgeSelfActivationMilliseconds", in: defaults) {
            settings.selfActivationDuration = pause
        }
        if let pause = pause(forKey: "remoteClipboardSyncNudgeReactivationMilliseconds", in: defaults) {
            settings.reactivationDuration = pause
        }
        if let pause = pause(forKey: "remoteClipboardSyncNudgePasteDelayMilliseconds", in: defaults) {
            settings.pasteDelay = pause
        }
        return settings
    }

    /// A number of milliseconds from 0 up to `maximumPause`, otherwise `nil`.
    private static func pause(forKey key: String, in defaults: UserDefaults) -> Duration? {
        guard let number = defaults.object(forKey: key) as? NSNumber else { return nil }
        let pause = Duration.milliseconds(number.intValue)
        guard pause >= .zero, pause <= maximumPause else { return nil }
        return pause
    }
}

/// The system side of a nudge. Tests inject a fake, so no test shows a window or activates
/// an app.
@MainActor
protocol RemoteClipboardSyncEnvironment: AnyObject {
    func frontmostApplication() -> RemoteClipboardSyncApplication?
    /// Whether Pavarotti is the active app.
    func isPavarottiActive() -> Bool
    /// Whether Pavarotti uses the regular activation policy, as it does while it shows a window.
    func usesRegularActivationPolicy() -> Bool
    /// How often the active Space changed so far, for the log.
    func activeSpaceChangeCount() -> Int
    /// Shows the helper window on the remote app's screen, makes it key and activates Pavarotti.
    func activatePavarotti(over remoteApplication: RemoteClipboardSyncApplication)
    /// Activates the remote app again. `false` when it no longer runs or refused.
    func activate(_ application: RemoteClipboardSyncApplication) -> Bool
    /// Activates the remote app and also makes it frontmost through Accessibility, for when
    /// the system declined the activation. `false` when neither worked.
    func bringToFront(_ application: RemoteClipboardSyncApplication) -> Bool
    /// Orders the helper window out, once another app is active again.
    func removeHelperWindow()
    /// Keeps the helper window as Pavarotti's key window while Pavarotti is still active and
    /// orders it out when Pavarotti resigns active.
    func removeHelperWindowWhenPavarottiResignsActive()
}

/// Activates Pavarotti for a moment and the remote app again, so the remote desktop client
/// transfers the clipboard. Only used for targets `RemoteSessionClassifier` recognizes.
@MainActor
final class RemoteClipboardSyncNudger {
    typealias Sleep = @MainActor @Sendable (Duration) async throws -> Void

    private static let logger = Logger(subsystem: "de.foxagon.pavarotti", category: "RemoteClipboardSync")

    private let environment: (any RemoteClipboardSyncEnvironment)?
    private let sleep: Sleep
    private let settingsProvider: () -> RemoteClipboardSyncNudgeSettings

    init(
        environment: (any RemoteClipboardSyncEnvironment)?,
        settingsProvider: @escaping () -> RemoteClipboardSyncNudgeSettings = {
            RemoteClipboardSyncNudgeSettings.load(from: .standard)
        },
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.environment = environment
        self.settingsProvider = settingsProvider
        self.sleep = sleep
    }

    /// Activates Pavarotti for `selfActivationDuration`, runs `whilePavarottiIsActive`,
    /// activates the remote app again, waits `reactivationDuration`, removes the helper window
    /// and waits `pasteDelay`.
    ///
    /// `whilePavarottiIsActive` runs once the remote app has lost focus for the whole pause, so
    /// the payload is written after Windows App sent the remote clipboard. It does not run when
    /// the nudge is cancelled or never activates Pavarotti.
    ///
    /// Cancellation cuts the self-activation short, but the remote app is still activated again
    /// and the reactivation pause still runs. The helper window only goes once Pavarotti is no
    /// longer active: closing its key window while it is active could make one of its windows
    /// on another Space key.
    func nudge(
        expectedBundleIdentifier: String?,
        whilePavarottiIsActive: () -> Void
    ) async -> RemoteClipboardSyncNudgeOutcome {
        let settings = settingsProvider()
        guard settings.isEnabled else { return .disabled }
        guard let environment else { return .unavailable }
        let frontmost = environment.frontmostApplication()
        guard let remote = frontmost, Self.matches(remote.bundleIdentifier, expectedBundleIdentifier) else {
            Self.logger.warning(
                "Nudge skipped, remote app not in front: expected=\(expectedBundleIdentifier ?? "nil", privacy: .public), frontmost=\(frontmost?.bundleIdentifier ?? "nil", privacy: .public)"
            )
            return .frontmostApplicationChanged
        }
        let isRegular = environment.usesRegularActivationPolicy()
        if isRegular, !settings.nudgesWhenRegular {
            Self.logger.warning("Nudge skipped while Pavarotti shows a window (remoteClipboardSyncNudgeWhenRegular is off)")
            return .skippedForRegularActivationPolicy
        }
        guard !Task.isCancelled else { return .cancelled }

        let start = ContinuousClock.now
        let spaceChangesBefore = environment.activeSpaceChangeCount()
        environment.activatePavarotti(over: remote)
        var completed = await wait(settings.selfActivationDuration)
        if completed {
            whilePavarottiIsActive()
        }
        let reactivation = await reactivate(remote, in: environment, settings: settings)
        let keptHelperWindow = environment.isPavarottiActive()
        if keptHelperWindow {
            environment.removeHelperWindowWhenPavarottiResignsActive()
        } else {
            environment.removeHelperWindow()
        }
        if completed {
            completed = await wait(settings.pasteDelay)
        }
        log(NudgeReport(
            remote: remote,
            reactivation: reactivation,
            remoteFrontmost: isFrontmost(remote),
            keptHelperWindow: keptHelperWindow,
            isRegular: isRegular,
            spaceChanges: environment.activeSpaceChangeCount() - spaceChangesBefore,
            cancelled: !completed,
            milliseconds: Int((start.duration(to: .now) / .milliseconds(1)).rounded())
        ))
        return completed ? .nudged(remote) : .cancelled
    }

    /// Whether `application` is the frontmost app right now. `false` without an environment.
    func isFrontmost(_ application: RemoteClipboardSyncApplication) -> Bool {
        environment?.frontmostApplication()?.processIdentifier == application.processIdentifier
    }

    /// Activates the remote app again and waits `reactivationDuration`. If it refused or is not
    /// in front after that, brings it to the front repeatedly while polling. Never cut short
    /// by cancellation: the remote app has to be back in front.
    private func reactivate(
        _ remote: RemoteClipboardSyncApplication,
        in environment: any RemoteClipboardSyncEnvironment,
        settings: RemoteClipboardSyncNudgeSettings
    ) async -> (reactivated: Bool, retried: Bool) {
        var reactivated = environment.activate(remote)
        await sleepIgnoringCancellation(settings.reactivationDuration)
        if reactivated, isFrontmost(remote) {
            return (true, false)
        }
        let frontmost = environment.frontmostApplication()?.bundleIdentifier ?? "nil"
        Self.logger.warning("Remote app not in front after the nudge, bringing it to the front: frontmost=\(frontmost, privacy: .public)")
        var waited = Duration.zero
        var nextAttempt = Duration.zero
        while !isFrontmost(remote), waited < settings.reactivationRetryTimeout {
            if waited >= nextAttempt {
                reactivated = environment.bringToFront(remote)
                nextAttempt += settings.reactivationRetryInterval
            }
            await sleepIgnoringCancellation(settings.reactivationRetryPollInterval)
            waited += settings.reactivationRetryPollInterval
        }
        return (reactivated, true)
    }

    /// Sleeps for `duration`. `false` when cancelled.
    private func wait(_ duration: Duration) async -> Bool {
        do {
            try await sleep(duration)
        } catch {
            return false
        }
        return !Task.isCancelled
    }

    /// Runs in its own task, which does not inherit the caller's cancellation.
    private func sleepIgnoringCancellation(_ duration: Duration) async {
        let pause = sleep
        _ = await Task { @MainActor in
            try await pause(duration)
        }.result
    }

    private func log(_ report: NudgeReport) {
        if report.isUnusual {
            Self.logger.warning("\(report.message, privacy: .public)")
        } else {
            Self.logger.info("\(report.message, privacy: .public)")
        }
    }

    private static func matches(_ bundleIdentifier: String?, _ expected: String?) -> Bool {
        guard let bundleIdentifier, let expected else { return false }
        return bundleIdentifier.caseInsensitiveCompare(expected) == .orderedSame
    }
}

/// What a nudge did, for the log.
private struct NudgeReport {
    let remote: RemoteClipboardSyncApplication
    let reactivation: (reactivated: Bool, retried: Bool)
    let remoteFrontmost: Bool
    let keptHelperWindow: Bool
    let isRegular: Bool
    let spaceChanges: Int
    let cancelled: Bool
    let milliseconds: Int

    /// Worth a warning: a Space may have switched or the remote app is not in front.
    var isUnusual: Bool {
        isRegular || spaceChanges > 0 || !remoteFrontmost
    }

    var message: String {
        "Nudge finished: remote=\(remote.bundleIdentifier ?? "nil"), reactivated=\(reactivation.reactivated), "
            + "retried=\(reactivation.retried), remoteFrontmost=\(remoteFrontmost), helperWindowKept=\(keptHelperWindow), "
            + "regularPolicy=\(isRegular), spaceChanges=\(spaceChanges), cancelled=\(cancelled), durationMs=\(milliseconds)"
    }
}
