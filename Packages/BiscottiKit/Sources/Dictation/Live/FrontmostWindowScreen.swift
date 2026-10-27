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
        guard let windowBounds = frontmostWindowBounds(of: processIdentifier), let primary = screens.first else {
            return nil
        }
        let index = bestScreenIndex(
            for: windowBounds,
            screenFrames: screens.map(\.frame),
            primaryScreenHeight: primary.frame.maxY
        )
        return index.map { screens[$0] }
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

    /// The bounds of the app's frontmost normal window.
    private static func frontmostWindowBounds(of processIdentifier: pid_t) -> CGRect? {
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
