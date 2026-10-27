import BiscottiTestSupport
import Foundation
import Testing
@testable import AppCore

/// Pavarotti: Settings is split into pages, and other screens can open it on one.
@Suite("AppCore -- Settings pages")
struct SettingsPaneTests {
    @Test("opening Settings on a page routes there and remembers the page")
    @MainActor
    func showSettingsOnPage() throws {
        let fix = try makeCoreFixture(testName: "SettingsPaneTests")
        defer { fix.cleanup() }
        let suite = "pavarotti.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        fix.core.showSettings(.intelligence, defaults: defaults)

        #expect(fix.core.route == .settings)
        #expect(defaults.string(forKey: SettingsPane.defaultsKey) == SettingsPane.intelligence.rawValue)
    }

    @Test("every page has a title, a symbol and a caption")
    func pagesAreLabeled() {
        #expect(SettingsPane.allCases.map(\.title) == ["Dictation", "Meetings", "AI", "General"])
        for pane in SettingsPane.allCases {
            #expect(!pane.systemImage.isEmpty)
            #expect(!pane.caption.isEmpty)
        }
    }
}
