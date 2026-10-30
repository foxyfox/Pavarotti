import CoreGraphics
import Testing
@testable import Dictation

@Suite("Screen of the frontmost window")
struct FrontmostWindowScreenTests {
    /// A laptop display with a larger display to its right, in AppKit coordinates.
    private let screens = [
        CGRect(x: 0, y: 0, width: 1512, height: 982),
        CGRect(x: 1512, y: -200, width: 2560, height: 1440)
    ]

    @Test("a window on the second display picks it")
    func secondDisplay() {
        let window = CGRect(x: 2000, y: 300, width: 900, height: 700)
        #expect(FrontmostWindowScreen.bestScreenIndex(for: window, screenFrames: screens, primaryScreenHeight: 982) == 1)
    }

    @Test("a window across both displays picks the one showing more of it")
    func straddling() {
        let mostlyLeft = CGRect(x: 800, y: 100, width: 900, height: 600)
        let mostlyRight = CGRect(x: 1300, y: 100, width: 900, height: 600)
        #expect(FrontmostWindowScreen.bestScreenIndex(for: mostlyLeft, screenFrames: screens, primaryScreenHeight: 982) == 0)
        #expect(FrontmostWindowScreen.bestScreenIndex(for: mostlyRight, screenFrames: screens, primaryScreenHeight: 982) == 1)
    }

    @Test("a window off every display picks none")
    func offScreen() {
        let window = CGRect(x: -5000, y: 0, width: 400, height: 300)
        #expect(FrontmostWindowScreen.bestScreenIndex(for: window, screenFrames: screens, primaryScreenHeight: 982) == nil)
    }

    /// A full-screen window on the second display, in window server coordinates.
    private let fullScreenContent = CGRect(x: 1512, y: -258, width: 2560, height: 1440)

    private func window(
        _ bounds: CGRect,
        owner: pid_t = 501,
        layer: Int = 0,
        alpha: Double = 1
    ) -> FrontmostWindowScreen.WindowInfo {
        FrontmostWindowScreen.WindowInfo(ownerProcessIdentifier: owner, layer: layer, alpha: alpha, bounds: bounds)
    }

    private func screenIndex(_ windows: [FrontmostWindowScreen.WindowInfo]) -> Int? {
        FrontmostWindowScreen.screenIndex(
            showingWindowOf: 501,
            windows: windows,
            screenFrames: screens,
            primaryScreenHeight: 982
        )
    }

    @Test("an invisible title bar window in front of a full-screen window is skipped")
    func hiddenTitleBar() {
        let titleBar = CGRect(x: 0, y: 0, width: 1512, height: 52)
        #expect(screenIndex([window(titleBar, alpha: 0), window(fullScreenContent)]) == 1)
    }

    @Test("windows without size or off every display are skipped")
    func emptyAndOffScreen() {
        let empty = CGRect(x: 100, y: 100, width: 0, height: 0)
        let offScreen = CGRect(x: -5000, y: 0, width: 400, height: 300)
        #expect(screenIndex([window(empty), window(offScreen), window(fullScreenContent)]) == 1)
    }

    @Test("other apps' windows do not count, and other layers only without a normal window")
    func ownersAndLayers() {
        let laptop = CGRect(x: 100, y: 100, width: 800, height: 600)
        #expect(screenIndex([window(laptop, owner: 600), window(fullScreenContent)]) == 1)
        #expect(screenIndex([window(laptop, layer: 3), window(fullScreenContent)]) == 1)
        #expect(screenIndex([window(laptop, layer: 3)]) == 0)
        #expect(screenIndex([window(laptop, owner: 600)]) == nil)
    }
}
