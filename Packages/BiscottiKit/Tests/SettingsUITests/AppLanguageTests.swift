import Foundation
import Testing
@testable import SettingsUI

// Pavarotti: the app language setting and the German texts it switches to.

@Suite("App language")
struct AppLanguageTests {
    @Test("the saved choice comes from the app's own AppleLanguages, the system's otherwise")
    func savedChoice() throws {
        let (defaults, domain) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }

        #expect(AppLanguage.saved(in: defaults, domain: domain) == .system)
        defaults.setPersistentDomain([AppLanguage.preferenceKey: ["de-DE", "en"]], forName: domain)
        #expect(AppLanguage.saved(in: defaults, domain: domain) == .german)
        defaults.setPersistentDomain([AppLanguage.preferenceKey: ["fr"]], forName: domain)
        #expect(AppLanguage.saved(in: defaults, domain: domain) == .system)
    }

    @Test("saving a language sets AppleLanguages, the system language removes it")
    func saving() throws {
        let (defaults, domain) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }

        AppLanguage.english.save(in: defaults)
        #expect(defaults.persistentDomain(forName: domain)?[AppLanguage.preferenceKey] as? [String] == ["en"])
        #expect(AppLanguage.saved(in: defaults, domain: domain) == .english)

        AppLanguage.system.save(in: defaults)
        #expect(defaults.persistentDomain(forName: domain)?[AppLanguage.preferenceKey] == nil)
        #expect(AppLanguage.saved(in: defaults, domain: domain) == .system)
    }

    @Test("the German texts parse and keep the placeholders of their English keys")
    func germanTexts() throws {
        let texts = try Self.strings(named: "Localizable")
        #expect(texts.count > 400)
        for (english, german) in texts {
            #expect(Self.placeholders(in: german) == Self.placeholders(in: english), "\(english)")
        }
        #expect(texts["App Language"] == "App-Sprache")
    }

    @Test("the permission prompts have German texts")
    func germanPermissionPrompts() throws {
        let texts = try Self.strings(named: "InfoPlist")
        #expect(Set(texts.keys) == [
            "NSMicrophoneUsageDescription", "NSAudioCaptureUsageDescription", "NSCalendarsFullAccessUsageDescription"
        ])
    }

    // MARK: - Helpers

    private func makeDefaults() throws -> (UserDefaults, String) {
        let domain = "pavarotti-app-language-test-\(UUID().uuidString)"
        return try (#require(UserDefaults(suiteName: domain)), domain)
    }

    /// A `.strings` file of the app's German localization, read as a property list.
    private static func strings(named name: String) throws -> [String: String] {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // SettingsUITests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // BiscottiKit
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent()
        let url = repo.appending(path: "App/Resources/de.lproj/\(name).strings")
        let list = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        return try #require(list as? [String: String])
    }

    /// The format placeholders in order, such as `%@` and `%lld`; `%%` is a literal percent sign.
    private static func placeholders(in text: String) -> [String] {
        text.matches(of: /%(?:\d+\$)?(?:lld|ld|d|lf|f|@)/).map { String($0.output) }
    }
}
