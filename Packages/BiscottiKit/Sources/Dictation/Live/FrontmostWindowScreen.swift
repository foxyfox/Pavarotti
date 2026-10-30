import AppKit

/// The screen that shows an app's frontmost window, from the window server. Needs no
/// permission: window bounds are public, only titles are not.
public enum FrontmostWindowScreen {
    /// The screen with the frontmost app's frontmost window.
    @MainActor
    public static func ofFrontmostApplication() -> NSScreen? {
        guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
        return screen(showingWindowOf: application.processIdentifier)
    }

    @MainActor
    public static func screen(showingWindowOf processIdentifier: pid_t) -> NSScreen? {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return nil }
        let index = screenIndex(
            showingWindowOf: processIdentifier,
            windows: onScreenWindows(),
            screenFrames: screens.map(\.frame),
            primaryScreenHeight: primary.frame.maxY
        )
        return index.map { screens[$0] }
    }

    /// The screen under the mouse pointer.
    @MainActor
    public static func withMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
    }

    /// A window from the window server's list, front to back.
    struct WindowInfo: Equatable {
        let ownerProcessIdentifier: pid_t
        let layer: Int
        let alpha: Double
        let bounds: CGRect
    }

    /// The index of the screen with the app's frontmost visible window. Normal windows
    /// (layer 0) come first. Windows without alpha, without size or off every screen are
    /// skipped: a full-screen app keeps such a window for its hidden title bar in front of
    /// the window that shows its content.
    static func screenIndex(
        showingWindowOf processIdentifier: pid_t,
        windows: [WindowInfo],
        screenFrames: [CGRect],
        primaryScreenHeight: CGFloat
    ) -> Int? {
        let visible = windows.filter { window in
            window.ownerProcessIdentifier == processIdentifier && window.alpha > 0 && !window.bounds.isEmpty
        }
        let candidates = visible.filter { $0.layer == 0 } + visible.filter { $0.layer != 0 }
        for window in candidates {
            if let index = bestScreenIndex(
                for: window.bounds,
                screenFrames: screenFrames,
                primaryScreenHeight: primaryScreenHeight
            ) {
                return index
            }
        }
        return nil
    }

    /// The index of the screen frame that shows most of the window. Window bounds start at
    /// the top left of the primary display, AppKit screen frames at its bottom left.
    static func bestScreenIndex(for windowBounds: CGRect, screenFrames: [CGRect], primaryScreenHeight: CGFloat) -> Int? {
        let frame = CGRect(
            x: windowBounds.minX,
            y: primaryScreenHeight - windowBounds.maxY,
            width: windowBounds.width,
            height: windowBounds.height
        )
        let overlaps = screenFrames.map { screenFrame -> CGFloat in
            let intersection = screenFrame.intersection(frame)
            return intersection.isNull ? 0 : intersection.width * intersection.height
        }
        guard let best = overlaps.indices.max(by: { overlaps[$0] < overlaps[$1] }), overlaps[best] > 0 else {
            return nil
        }
        return best
    }

    /// Every window on screen, front to back.
    private static func onScreenWindows() -> [WindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        // Keys spelled out: the kCGWindow… constants are these strings.
        return windows.compactMap { info in
            guard let owner = info["kCGWindowOwnerPID"] as? Int,
                  let boundsDictionary = info["kCGWindowBounds"] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary)
            else {
                return nil
            }
            return WindowInfo(
                ownerProcessIdentifier: pid_t(owner),
                layer: info["kCGWindowLayer"] as? Int ?? 0,
                alpha: info["kCGWindowAlpha"] as? Double ?? 1,
                bounds: bounds
            )
        }
    }
}
