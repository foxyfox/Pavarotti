import MeetingCatalog
import Testing

/// Pavarotti: Firefox, Edge and Brave count as meeting hosts, and helper
/// processes that extend an app's bundle ID count as that app.
@Suite("BundledMeetingCatalog browsers and helpers")
struct BrowserHelperTests {
    let catalog = BundledMeetingCatalog()

    @Test("Firefox, Edge and Brave are meeting hosts", arguments: [
        ("org.mozilla.firefox", "Firefox"),
        ("com.microsoft.edgemac", "Microsoft Edge"),
        ("com.brave.Browser", "Brave Browser")
    ])
    func browsers(bundleID: String, name: String) {
        #expect(catalog.isMeetingApp(bundleID: bundleID))
        #expect(catalog.displayName(forBundleID: bundleID) == name)
        #expect(catalog.parentBundleID(forHelperBundleID: bundleID) == nil)
    }

    @Test("Helpers that extend an app's bundle ID resolve to that app", arguments: [
        ("com.google.Chrome.helper", "com.google.Chrome", "Google Chrome"),
        ("com.microsoft.edgemac.helper", "com.microsoft.edgemac", "Microsoft Edge"),
        ("com.brave.Browser.helper.renderer", "com.brave.Browser", "Brave Browser"),
        ("company.thebrowser.Browser.helper", "company.thebrowser.Browser", "Arc Browser"),
        ("us.zoom.xos.Hotkey", "us.zoom.xos", "Zoom"),
    ])
    func prefixHelpers(helperID: String, parentID: String, name: String) {
        #expect(catalog.isMeetingApp(bundleID: helperID))
        #expect(catalog.parentBundleID(forHelperBundleID: helperID) == parentID)
        #expect(catalog.displayName(forBundleID: helperID) == name)
    }

    @Test("Listed helpers keep their explicit parent")
    func explicitHelpers() {
        #expect(catalog.parentBundleID(forHelperBundleID: "com.microsoft.teams2.helper") == "com.microsoft.teams2")
        #expect(catalog.parentBundleID(forHelperBundleID: "com.apple.WebKit.GPU") == "com.apple.Safari")
    }

    @Test("Look-alike bundle IDs are not meeting apps", arguments: [
        "com.google.Chromecast",
        "com.brave.BrowserBeta",
        "org.mozilla.thunderbird",
    ])
    func lookAlikes(bundleID: String) {
        #expect(!catalog.isMeetingApp(bundleID: bundleID))
        #expect(catalog.parentBundleID(forHelperBundleID: bundleID) == nil)
    }
}
