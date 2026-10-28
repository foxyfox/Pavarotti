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
    func explicitLanguages() {
        #expect(LanguagePolicy.firstRequest(for: .german, detectionAvailable: true) == "de")
        #expect(LanguagePolicy.firstRequest(for: .english, detectionAvailable: true) == "en")
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
}
