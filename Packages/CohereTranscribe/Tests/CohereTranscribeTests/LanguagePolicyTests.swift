import Foundation
import Testing
@testable import CohereTranscribe

@Suite("Language policy")
struct LanguagePolicyTests {
    @Test("Automatic asks the server to detect when language ID is installed")
    func automaticWithDetection() {
        #expect(LanguagePolicy.firstRequest(for: .automatic, detectionAvailable: true) == "auto")
    }

    @Test("Automatic falls back to German without language ID")
    func automaticWithoutDetection() {
        #expect(LanguagePolicy.firstRequest(for: .automatic, detectionAvailable: false) == "de")
    }

    @Test("Explicit languages are sent as they are")
    func explicitLanguages() throws {
        #expect(LanguagePolicy.firstRequest(for: .german, detectionAvailable: true) == "de")
        #expect(LanguagePolicy.firstRequest(for: .english, detectionAvailable: true) == "en")
        let french = try #require(TranscriptionLanguage(rawValue: "fr"))
        #expect(LanguagePolicy.firstRequest(for: french, detectionAvailable: false) == "fr")
    }

    @Test("German and English detections are kept", arguments: ["de", "en", "de-DE", "EN", "German"])
    func acceptedDetections(detected: String) {
        #expect(LanguagePolicy.retryLanguage(afterRequesting: "auto", detected: detected) == nil)
    }

    @Test("Other detections are redone in German", arguments: ["nl", "fr", "und"])
    func otherDetections(detected: String) {
        #expect(LanguagePolicy.retryLanguage(afterRequesting: "auto", detected: detected) == "de")
        #expect(LanguagePolicy.resolvedLanguage(requested: "auto", detected: detected) == "de")
    }

    @Test("A missing detection is redone in German")
    func missingDetection() {
        #expect(LanguagePolicy.retryLanguage(afterRequesting: "auto", detected: nil) == "de")
    }

    @Test("Explicit requests are never redone")
    func explicitNeverRetried() {
        #expect(LanguagePolicy.retryLanguage(afterRequesting: "en", detected: "nl") == nil)
        #expect(LanguagePolicy.retryLanguage(afterRequesting: "de", detected: nil) == nil)
        #expect(LanguagePolicy.resolvedLanguage(requested: "en", detected: "de") == "en")
    }

    @Test("The resolved language is the detected one when accepted")
    func resolvedFromDetection() {
        #expect(LanguagePolicy.resolvedLanguage(requested: "auto", detected: "en-US") == "en")
    }

    @Test("A model that writes what it hears reports what it detected")
    func heardLanguage() {
        #expect(LanguagePolicy.heardLanguage(requested: "de", detected: "en") == "en")
        #expect(LanguagePolicy.heardLanguage(requested: "auto", detected: "German") == "de")
        #expect(LanguagePolicy.heardLanguage(requested: "en", detected: nil) == "en")
        #expect(LanguagePolicy.heardLanguage(requested: "auto", detected: "fr") == "de")
    }

    @Test("Any other chosen language is kept, also by a model that writes what it hears")
    func otherChosenLanguages() {
        #expect(LanguagePolicy.retryLanguage(afterRequesting: "fr", detected: "de") == nil)
        #expect(LanguagePolicy.resolvedLanguage(requested: "sv", detected: nil) == "sv")
        #expect(LanguagePolicy.heardLanguage(requested: "fr", detected: "fr") == "fr")
        #expect(LanguagePolicy.heardLanguage(requested: "sv", detected: nil) == "sv")
    }

    // MARK: - Languages

    @Test("A language is automatic or a two-letter code", arguments: ["auto", "de", "fr", "uk"])
    func validLanguages(raw: String) throws {
        let language = try #require(TranscriptionLanguage(rawValue: raw))
        #expect(language.code == (raw == "auto" ? nil : raw))
    }

    @Test("Anything else is no language", arguments: ["", "klingon", "DE", "d", "de-DE"])
    func invalidLanguages(raw: String) {
        #expect(TranscriptionLanguage(rawValue: raw) == nil)
    }

    @Test("Languages are stored as their plain code, as before")
    func storedAsCode() throws {
        #expect(try JSONEncoder().encode([TranscriptionLanguage.automatic, .german]) == Data(#"["auto","de"]"#.utf8))
        let decoded = try JSONDecoder().decode([TranscriptionLanguage].self, from: Data(#"["en","pl"]"#.utf8))
        #expect(decoded.map(\.rawValue) == ["en", "pl"])
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(TranscriptionLanguage.self, from: Data(#""klingon""#.utf8))
        }
    }

    @Test("Each model offers the languages of its model card")
    func modelLanguages() throws {
        #expect(CohereModel.fast.languages.count == 14)
        #expect(CohereModel.small.languages.count == 25)
        for model in CohereModel.all {
            #expect(Set(model.languages).isSuperset(of: ["de", "en"]))
            #expect(Set(model.languages).count == model.languages.count)
            #expect(model.supports(.automatic))
        }
        let swedish = try #require(TranscriptionLanguage(rawValue: "sv"))
        let japanese = try #require(TranscriptionLanguage(rawValue: "ja"))
        #expect(CohereModel.small.supports(swedish))
        #expect(!CohereModel.small.supports(japanese))
        #expect(CohereModel.compact.supports(japanese))
        #expect(!CohereModel.compact.supports(swedish))
    }
}
