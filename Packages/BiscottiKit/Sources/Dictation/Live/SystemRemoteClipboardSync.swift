import AppKit
import os

/// The real side of the remote clipboard sync: activates apps and shows the helper window.
@MainActor
final class SystemRemoteClipboardSyncEnvironment: RemoteClipboardSyncEnvironment {
    private static let logger = Logger(subsystem: "de.foxagon.pavarotti", category: "RemoteClipboardSync")

    private var helperWindow: RemoteClipboardSyncHelperWindow?
    private var resignActiveObserver: (any NSObjectProtocol)?
    private var spaceChangeObserver: (any NSObjectProtocol)?
    private var activeSpaceChanges = 0

    func frontmostApplication() -> RemoteClipboardSyncApplication? {
        guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
        return RemoteClipboardSyncApplication(
            processIdentifier: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier
        )
    }

    func isPavarottiActive() -> Bool {
        NSApp.isActive
    }

    func usesRegularActivationPolicy() -> Bool {
        NSApp.activationPolicy() == .regular
    }

    func activeSpaceChangeCount() -> Int {
        activeSpaceChanges
    }

    func activatePavarotti(over remoteApplication: RemoteClipboardSyncApplication) {
        observeActiveSpaceChanges()
        // A helper window kept from an earlier nudge is reused; this nudge decides when it goes.
        stopWaitingForResignActive()
        let window = helperWindow ?? RemoteClipboardSyncHelperWindow()
        helperWindow = window
        if let screen = Self.screen(showing: remoteApplication) ?? NSScreen.main ?? NSScreen.screens.first {
            window.setFrame(NSRect(x: screen.frame.minX, y: screen.frame.minY, width: 1, height: 1), display: false)
        }
        // The key window on the active Space comes first, so the activation stays on this
        // Space instead of switching to another Pavarotti window.
        window.orderFrontRegardless()
        window.makeKey()
        // The cooperative `activate()` may decline to activate an app in the background; the
        // measured nudge used the forced variant.
        Self.activateIgnoringOtherApps()
    }

    /// `NSApp.activate(ignoringOtherApps: true)`, called through the runtime: it is
    /// deprecated since macOS 14, and the build treats warnings as errors.
    private static func activateIgnoringOtherApps() {
        typealias Activate = @convention(c) (AnyObject, Selector, Bool) -> Void
        let selector = NSSelectorFromString("activateIgnoringOtherApps:")
        guard let method = class_getInstanceMethod(NSApplication.self, selector) else {
            NSApp.activate()
            return
        }
        let activate = unsafeBitCast(method_getImplementation(method), to: Activate.self)
        activate(NSApp, selector, true)
    }

    func activate(_ application: RemoteClipboardSyncApplication) -> Bool {
        guard let running = NSRunningApplication(processIdentifier: application.processIdentifier),
              !running.isTerminated
        else {
            return false
        }
        return running.activate()
    }

    func removeHelperWindow() {
        stopWaitingForResignActive()
        helperWindow?.orderOut(nil)
    }

    func removeHelperWindowWhenPavarottiResignsActive() {
        guard resignActiveObserver == nil else { return }
        Self.logger.warning("Pavarotti is still active after the nudge; the helper window stays until it resigns active")
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.removeHelperWindow()
            }
        }
    }

    private func stopWaitingForResignActive() {
        if let resignActiveObserver {
            NotificationCenter.default.removeObserver(resignActiveObserver)
        }
        resignActiveObserver = nil
    }

    private func observeActiveSpaceChanges() {
        guard spaceChangeObserver == nil else { return }
        spaceChangeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.activeSpaceChanges += 1
            }
        }
    }

    /// The screen with the remote app's frontmost window, so the helper window does not move
    /// the keyboard focus to another display.
    private static func screen(showing application: RemoteClipboardSyncApplication) -> NSScreen? {
        guard let windowFrame = frontmostWindowFrame(of: application.processIdentifier),
              let primaryScreen = NSScreen.screens.first
        else {
            return nil
        }
        // Window bounds start at the top left of the primary display, AppKit frames at its
        // bottom left.
        let frame = NSRect(
            x: windowFrame.minX,
            y: primaryScreen.frame.maxY - windowFrame.maxY,
            width: windowFrame.width,
            height: windowFrame.height
        )
        func overlap(_ screen: NSScreen) -> CGFloat {
            let intersection = screen.frame.intersection(frame)
            return intersection.isNull ? 0 : intersection.width * intersection.height
        }
        guard let screen = NSScreen.screens.max(by: { overlap($0) < overlap($1) }), overlap(screen) > 0 else {
            return nil
        }
        return screen
    }

    /// The bounds of the app's frontmost normal window, from the window server.
    private static func frontmostWindowFrame(of processIdentifier: pid_t) -> CGRect? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return nil }
        // Keys spelled out: the kCGWindow… constants are these strings.
        let window = windows.first { info in
            (info["kCGWindowOwnerPID"] as? Int).map(pid_t.init) == processIdentifier
                && (info["kCGWindowLayer"] as? Int) == 0
        }
        guard let bounds = window?["kCGWindowBounds"] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: bounds as CFDictionary)
    }
}

/// A 1×1 transparent window that ignores the mouse and stays out of the Window menu, window
/// cycling and Mission Control. As Pavarotti's key window on the active Space it keeps the
/// activation on that Space, also next to a full-screen window.
final class RemoteClipboardSyncHelperWindow: NSWindow {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        identifier = NSUserInterfaceItemIdentifier("de.foxagon.pavarotti.remoteClipboardSyncHelper")
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .floating
        collectionBehavior = [.moveToActiveSpace, .transient, .ignoresCycle, .fullScreenAuxiliary]
        isExcludedFromWindowsMenu = true
        hidesOnDeactivate = false
        animationBehavior = .none
        sharingType = .none
        setAccessibilityElement(false)
    }

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }
}
