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
}
